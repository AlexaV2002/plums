import {
  Ack,
  ConnectedSocket,
  MessageBody,
  OnGatewayConnection,
  OnGatewayDisconnect,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
} from '@nestjs/websockets';
import { JwtService } from '@nestjs/jwt';
import { Logger } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import { PrismaService } from '../prisma/prisma.service';

type JwtPayload = {
  sub: string;
  email: string;
  exp?: number;
};

type SocketSessionData = {
  userId?: string;
  authExpiresAt?: number;
  authVersion?: number;
  identityVersion?: number;
  expireSession?: () => void;
};

const roomOperations = new WeakMap<Socket, Promise<void>>();

function enqueueRoomOperation(client: Socket, task: () => Promise<void>) {
  const previous = roomOperations.get(client) ?? Promise.resolve();
  const next = previous.catch(() => undefined).then(task);
  roomOperations.set(client, next);
  const cleanup = () => {
    if (roomOperations.get(client) === next) roomOperations.delete(client);
  };
  void next.then(cleanup, cleanup);
  return next;
}

export function getActiveSocketIdentity(client: Socket) {
  const data = client.data as SocketSessionData;
  if (
    client.connected === false ||
    !data.userId ||
    !Number.isFinite(data.authExpiresAt) ||
    !Number.isInteger(data.identityVersion)
  ) {
    return null;
  }
  if (Date.now() >= data.authExpiresAt!) {
    data.expireSession?.();
    return null;
  }
  return { userId: data.userId, version: data.identityVersion! };
}

export function isSocketIdentityCurrent(
  client: Socket,
  identity: { userId: string; version: number },
) {
  const current = getActiveSocketIdentity(client);
  return (
    current?.userId === identity.userId && current.version === identity.version
  );
}

export function joinProtectedRoom(
  client: Socket,
  room: string,
  identity: { userId: string; version: number },
) {
  return enqueueRoomOperation(client, async () => {
    if (!isSocketIdentityCurrent(client, identity)) return;
    await client.join(room);
    if (!isSocketIdentityCurrent(client, identity)) await client.leave(room);
  });
}

function leaveProtectedRooms(client: Socket) {
  return enqueueRoomOperation(client, async () => {
    for (const room of [...client.rooms]) {
      if (
        room.startsWith('dm:') ||
        room.startsWith('server:') ||
        room.startsWith('channel:')
      ) {
        await client.leave(room);
      }
    }
  });
}

function isDisconnected(client: Socket) {
  return client.connected === false;
}

type UserStatus = 'ONLINE' | 'OFFLINE' | 'AWAY' | 'DO_NOT_DISTURB';

@WebSocketGateway({
  cors: {
    origin: '*',
  },
})
export class UsersGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server!: Server;

  private readonly connectionsByUser = new Map<string, number>();
  private readonly expiryTimers = new WeakMap<Socket, NodeJS.Timeout>();
  private readonly operations = new WeakMap<Socket, Promise<void>>();
  private readonly statusOperationsByUser = new Map<string, Promise<void>>();
  private readonly logger = new Logger(UsersGateway.name);

  constructor(
    private readonly jwtService: JwtService,
    private readonly prisma: PrismaService,
  ) {}

  handleConnection() {
    return;
  }

  @SubscribeMessage('presence:identify')
  async identify(
    @MessageBody() payload: { token?: string },
    @ConnectedSocket() client: Socket,
    // Ack-подтверждение идентификации. Клиент обязан присоединяться к
    // комнатам dm:* только после получения этого ack: установка
    // client.data.userId происходит асинхронно относительно emitWithAck
    // на клиенте, и dm:join без подтверждённого userId будет отклонён.
    @Ack() ack?: (response?: { userId: string }) => void,
  ) {
    return this.enqueue(client, async () => {
      const result = await this.verifyToken(payload?.token);
      if (isDisconnected(client)) return;

      if ('reason' in result) {
        const previous = this.invalidate(client);
        await previous.roomsLeft;
        if (previous.userId) await this.releaseUser(previous.userId);
        client.emit('session:expired', { reason: result.reason });
        return;
      }

      const data = client.data as SocketSessionData;
      if (data.userId === result.userId) {
        this.setIdentity(client, result.userId, result.expiresAt);
        ack?.({ userId: result.userId });
        return;
      }

      // Identity закрывается до первого await очистки комнат: параллельный join
      // не сможет вступить в комнату старого пользователя.
      const previous = this.invalidate(client);
      await previous.roomsLeft;
      if (previous.userId) await this.releaseUser(previous.userId);
      if (isDisconnected(client)) return;

      const connections = this.connectionsByUser.get(result.userId) ?? 0;
      this.connectionsByUser.set(result.userId, connections + 1);
      this.setIdentity(client, result.userId, result.expiresAt);
      if (connections === 0) {
        await this.queuePresenceUpdate(result.userId);
      }
      if (
        !isDisconnected(client) &&
        getActiveSocketIdentity(client)?.userId === result.userId
      ) {
        ack?.({ userId: result.userId });
      }
    });
  }

  async handleDisconnect(client: Socket) {
    const previous = this.invalidate(client);
    await this.enqueue(client, async () => {
      await previous.roomsLeft;
      if (previous.userId) await this.releaseUser(previous.userId);
    });
  }

  async emitUserStatus(userId: string, status: UserStatus) {
    // Статус виден только самому пользователю и участникам общих серверов.
    // Проверяем членство непосредственно перед отправкой каждому сокету;
    // повторная проверка identity исключает доставку после смены аккаунта.
    const sockets = this.server?.sockets?.sockets;
    if (!sockets) return;
    for (const socket of sockets.values()) {
      const identity = getActiveSocketIdentity(socket);
      if (!identity) continue;

      let visible = identity.userId === userId;
      if (!visible) {
        try {
          visible = Boolean(
            await this.prisma.serverMember.findFirst({
              where: {
                userId: identity.userId,
                server: { members: { some: { userId } } },
              },
              select: { id: true },
            }),
          );
        } catch {
          // Ошибка проверки одного получателя не должна превращать уже
          // сохранённое изменение статуса в ошибочный ответ REST/identify.
          this.logger.warn('Не удалось проверить доступ к событию user:status');
          continue;
        }
      }
      if (visible && isSocketIdentityCurrent(socket, identity)) {
        socket.emit('user:status', { userId, status });
      }
    }
  }

  private async updateAndEmitStatus(userId: string, status: UserStatus) {
    await this.prisma.user.update({
      where: {
        id: userId,
      },
      data: {
        status,
      },
    });

    await this.emitUserStatus(userId, status);
  }

  private async verifyToken(
    token?: string,
  ): Promise<
    | { userId: string; expiresAt: number }
    | { reason: 'token_expired' | 'invalid_token' }
  > {
    if (!token) return { reason: 'invalid_token' };
    try {
      const payload = await this.jwtService.verifyAsync<JwtPayload>(token, {
        secret: process.env.JWT_SECRET,
      });
      if (
        typeof payload.sub !== 'string' ||
        !payload.sub ||
        typeof payload.exp !== 'number' ||
        !Number.isFinite(payload.exp)
      ) {
        return { reason: 'invalid_token' };
      }
      const expiresAt = payload.exp * 1000;
      if (expiresAt <= Date.now()) return { reason: 'token_expired' };
      return { userId: payload.sub, expiresAt };
    } catch (error) {
      return {
        reason:
          error instanceof Error && error.name === 'TokenExpiredError'
            ? 'token_expired'
            : 'invalid_token',
      };
    }
  }

  private setIdentity(client: Socket, userId: string, expiresAt: number) {
    this.clearExpiryTimer(client);
    const data = client.data as SocketSessionData;
    const version = (data.authVersion ?? 0) + 1;
    data.userId = userId;
    data.authExpiresAt = expiresAt;
    data.authVersion = version;
    data.expireSession = () => this.expireNow(client, version);
    const timer = setTimeout(
      () => this.expireNow(client, version),
      Math.max(0, expiresAt - Date.now()),
    );
    timer.unref?.();
    this.expiryTimers.set(client, timer);
  }

  private expireNow(client: Socket, version: number) {
    const data = client.data as SocketSessionData;
    if (data.authVersion !== version || !data.userId) return;
    const previous = this.invalidate(client);
    client.emit('session:expired', { reason: 'token_expired' });
    void this.enqueue(client, async () => {
      await previous.roomsLeft;
      if (previous.userId) await this.releaseUser(previous.userId);
    }).catch((error: unknown) => {
      this.logger.error('Failed to release expired socket session', error);
    });
  }

  private invalidate(client: Socket) {
    this.clearExpiryTimer(client);
    const data = client.data as SocketSessionData;
    const userId = data.userId;
    data.userId = undefined;
    data.authExpiresAt = undefined;
    data.authVersion = (data.authVersion ?? 0) + 1;
    data.identityVersion = (data.identityVersion ?? 0) + 1;
    data.expireSession = undefined;
    const roomsLeft = leaveProtectedRooms(client);
    return { userId, roomsLeft };
  }

  private clearExpiryTimer(client: Socket) {
    const timer = this.expiryTimers.get(client);
    if (timer) clearTimeout(timer);
    this.expiryTimers.delete(client);
  }

  private async releaseUser(userId: string) {
    const connections = this.connectionsByUser.get(userId) ?? 0;
    if (connections <= 0) return;
    if (connections > 1) {
      this.connectionsByUser.set(userId, connections - 1);
      return;
    }
    this.connectionsByUser.delete(userId);
    await this.queuePresenceUpdate(userId);
  }

  private queuePresenceUpdate(userId: string) {
    const previous =
      this.statusOperationsByUser.get(userId) ?? Promise.resolve();
    const next = previous
      .catch(() => undefined)
      .then(async () => {
        const status =
          (this.connectionsByUser.get(userId) ?? 0) > 0 ? 'ONLINE' : 'OFFLINE';
        await this.updateAndEmitStatus(userId, status);
      });
    this.statusOperationsByUser.set(userId, next);
    const cleanup = () => {
      if (this.statusOperationsByUser.get(userId) === next) {
        this.statusOperationsByUser.delete(userId);
      }
    };
    void next.then(cleanup, cleanup);
    return next;
  }

  private enqueue(client: Socket, task: () => Promise<void>) {
    const previous = this.operations.get(client) ?? Promise.resolve();
    const next = previous.catch(() => undefined).then(task);
    this.operations.set(client, next);
    const cleanup = () => {
      if (this.operations.get(client) === next) this.operations.delete(client);
    };
    void next.then(cleanup, cleanup);
    return next;
  }
}
