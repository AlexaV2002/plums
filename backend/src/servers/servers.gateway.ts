import {
  ConnectedSocket,
  MessageBody,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';
import { PrismaService } from '../prisma/prisma.service';
import {
  getActiveSocketIdentity,
  isSocketIdentityCurrent,
  joinProtectedRoom,
} from '../users/users.gateway';

export type MemberLeavePayload = {
  serverId: string;
  userId: string;
  memberId: string;
  reason: 'leave' | 'kick' | 'ban';
};

export type MemberJoinPayload = {
  id: string;
  serverId: string;
  userId: string;
  joinedAt: Date;
  user: {
    id: string;
    username: string;
    avatarUrl: string | null;
    status: string;
    bio: string | null;
  };
};

export type RolePayload = {
  id: string;
  name: string;
  color: string | null;
  position: number;
};

export type RoleEventPayload = {
  serverId: string;
  role: RolePayload;
};

export type RoleDeletePayload = {
  serverId: string;
  roleId: string;
};

export type MemberRolesUpdatePayload = {
  serverId: string;
  memberId: string;
  userId: string;
  roles: RolePayload[];
};

@WebSocketGateway({
  cors: {
    origin: '*',
  },
})
export class ServersGateway {
  @WebSocketServer()
  server!: Server;

  constructor(private readonly prisma: PrismaService) {}

  @SubscribeMessage('server:join')
  async joinServer(
    @MessageBody() payload: { serverId?: string },
    @ConnectedSocket() client: Socket,
  ) {
    const identity = getActiveSocketIdentity(client);
    if (typeof payload?.serverId !== 'string' || !identity) {
      return;
    }

    const member = await this.prisma.serverMember.findUnique({
      where: {
        serverId_userId: {
          serverId: payload.serverId,
          userId: identity.userId,
        },
      },
    });
    if (!isSocketIdentityCurrent(client, identity)) return;
    if (!member) {
      client.emit('server:error', {
        serverId: payload.serverId,
        error: 'Нет доступа к серверу',
      });
      return;
    }

    const room = this.getServerRoom(payload.serverId);
    await joinProtectedRoom(client, room, identity);
  }

  @SubscribeMessage('server:leave')
  async leaveServer(
    @MessageBody() payload: { serverId?: string },
    @ConnectedSocket() client: Socket,
  ) {
    if (typeof payload?.serverId !== 'string') {
      return;
    }

    await client.leave(this.getServerRoom(payload.serverId));
  }

  emitMemberLeave(payload: MemberLeavePayload) {
    this.server
      .to(this.getServerRoom(payload.serverId))
      .emit('member:leave', payload);
  }

  emitMemberJoin(payload: MemberJoinPayload) {
    this.server
      .to(this.getServerRoom(payload.serverId))
      .emit('member:join', payload);
  }

  emitRoleNew(payload: RoleEventPayload) {
    this.server
      .to(this.getServerRoom(payload.serverId))
      .emit('role:new', payload);
  }

  emitRoleUpdate(payload: RoleEventPayload) {
    this.server
      .to(this.getServerRoom(payload.serverId))
      .emit('role:update', payload);
  }

  emitRoleDelete(payload: RoleDeletePayload) {
    this.server
      .to(this.getServerRoom(payload.serverId))
      .emit('role:delete', payload);
  }

  emitMemberRolesUpdate(payload: MemberRolesUpdatePayload) {
    this.server
      .to(this.getServerRoom(payload.serverId))
      .emit('member:roles:update', payload);
  }

  async evictUserFromServer(serverId: string, userId: string) {
    const channels = await this.prisma.channel.findMany({
      where: { serverId },
      select: { id: true },
    });
    const rooms = new Set([
      this.getServerRoom(serverId),
      ...channels.map((channel) => `channel:${channel.id}`),
    ]);
    for (const socket of await this.server.fetchSockets()) {
      if ((socket.data as { userId?: string }).userId !== userId) continue;
      for (const room of rooms) {
        if (socket.rooms.has(room)) socket.leave(room);
      }
    }
  }

  evictServerRooms(serverId: string, channelIds: string[]) {
    const rooms = [
      this.getServerRoom(serverId),
      ...channelIds.map((id) => `channel:${id}`),
    ];
    for (const room of rooms) this.server.in(room).socketsLeave(room);
  }

  private getServerRoom(serverId: string) {
    return `server:${serverId}`;
  }
}
