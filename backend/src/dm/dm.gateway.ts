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
import type { DmMessage } from './dm.service';

export type DmJoinAck =
  | { joined: true; conversationId: string }
  | {
      joined: false;
      conversationId: string | null;
      reason: 'unidentified' | 'not_found' | 'forbidden';
    };

@WebSocketGateway({
  cors: {
    origin: '*',
  },
})
export class DmGateway {
  @WebSocketServer()
  server!: Server;

  constructor(private readonly prisma: PrismaService) {}

  // Вступление в комнату личного диалога разрешается только после
  // presence:identify (client.data.userId) и проверки участия в диалоге.
  // Возвращаемое значение NestJS отправляет клиенту как ack.
  @SubscribeMessage('dm:join')
  async joinConversation(
    @MessageBody() payload: { conversationId?: string },
    @ConnectedSocket() client: Socket,
  ): Promise<DmJoinAck> {
    const conversationId = payload?.conversationId;

    if (typeof conversationId !== 'string' || !conversationId) {
      return { joined: false, conversationId: null, reason: 'not_found' };
    }

    const identity = getActiveSocketIdentity(client);

    if (!identity) {
      client.emit('dm:error', {
        conversationId,
        error: 'Требуется presence:identify перед вступлением в диалог',
      });
      return { joined: false, conversationId, reason: 'unidentified' };
    }

    const conversation = await this.prisma.directConversation.findUnique({
      where: { id: conversationId },
    });

    if (!conversation) {
      client.emit('dm:error', { conversationId, error: 'Диалог не найден' });
      return { joined: false, conversationId, reason: 'not_found' };
    }

    if (!isSocketIdentityCurrent(client, identity)) {
      return { joined: false, conversationId, reason: 'unidentified' };
    }
    if (
      conversation.userA !== identity.userId &&
      conversation.userB !== identity.userId
    ) {
      client.emit('dm:error', {
        conversationId,
        error: 'Вы не участник этого диалога',
      });
      return { joined: false, conversationId, reason: 'forbidden' };
    }

    const room = this.getRoom(conversationId);
    await joinProtectedRoom(client, room, identity);

    // Identity могла смениться, пока ждали очередь операций с комнатами:
    // joinProtectedRoom в этом случае уже покинул комнату.
    if (!isSocketIdentityCurrent(client, identity)) {
      return { joined: false, conversationId, reason: 'unidentified' };
    }

    return { joined: true, conversationId };
  }

  @SubscribeMessage('dm:leave')
  leaveConversation(
    @MessageBody() payload: { conversationId?: string },
    @ConnectedSocket() client: Socket,
  ) {
    if (!payload?.conversationId) {
      return;
    }

    void client.leave(this.getRoom(payload.conversationId));
  }

  emitMessageNew(conversationId: string, message: DmMessage) {
    this.server.to(this.getRoom(conversationId)).emit('dm:new', message);
  }

  // Получатель может держать вкладку ЛС открытой, ещё не зная о новом
  // диалоге и потому не находясь в комнате dm:<id>. Передаём только id,
  // а список и права перечитываются через защищённый REST endpoint.
  emitConversationChanged(userId: string, conversationId: string) {
    const sockets = this.server?.sockets?.sockets;
    if (!sockets) return;
    for (const socket of sockets.values()) {
      const identity = getActiveSocketIdentity(socket);
      if (
        identity?.userId === userId &&
        isSocketIdentityCurrent(socket, identity)
      ) {
        socket.emit('dm:conversation:changed', { conversationId });
      }
    }
  }

  emitMessageDelete(conversationId: string, payload: { id: string }) {
    this.server.to(this.getRoom(conversationId)).emit('dm:delete', {
      id: payload.id,
      conversationId,
    });
  }

  private getRoom(conversationId: string) {
    return `dm:${conversationId}`;
  }
}
