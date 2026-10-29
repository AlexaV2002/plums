import {
  ConnectedSocket,
  MessageBody,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';
import { PrismaService } from '../prisma/prisma.service';

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
  @SubscribeMessage('dm:join')
  async joinConversation(
    @MessageBody() payload: { conversationId?: string },
    @ConnectedSocket() client: Socket,
  ) {
    const conversationId = payload?.conversationId;

    if (!conversationId) {
      return;
    }

    const userId = client.data.userId as string | undefined;

    if (!userId) {
      client.emit('dm:error', {
        conversationId,
        error: 'Требуется presence:identify перед вступлением в диалог',
      });
      return;
    }

    const conversation = await this.prisma.directConversation.findUnique({
      where: { id: conversationId },
    });

    if (!conversation) {
      client.emit('dm:error', { conversationId, error: 'Диалог не найден' });
      return;
    }

    if (conversation.userA !== userId && conversation.userB !== userId) {
      client.emit('dm:error', {
        conversationId,
        error: 'Вы не участник этого диалога',
      });
      return;
    }

    client.join(this.getRoom(conversationId));
  }

  @SubscribeMessage('dm:leave')
  leaveConversation(
    @MessageBody() payload: { conversationId?: string },
    @ConnectedSocket() client: Socket,
  ) {
    if (!payload?.conversationId) {
      return;
    }

    client.leave(this.getRoom(payload.conversationId));
  }

  emitMessageNew(conversationId: string, message: unknown) {
    this.server.to(this.getRoom(conversationId)).emit('dm:new', message);
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
