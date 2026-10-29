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
export class MessagesGateway {
  @WebSocketServer()
  server!: Server;

  constructor(private readonly prisma: PrismaService) {}

  @SubscribeMessage('channel:join')
  async joinChannel(
    @MessageBody() payload: { channelId?: string },
    @ConnectedSocket() client: Socket,
  ) {
    const userId = (client.data as { userId?: string }).userId;
    if (typeof payload?.channelId !== 'string' || !userId) {
      return;
    }

    const channel = await this.prisma.channel.findUnique({
      where: { id: payload.channelId },
      include: { server: true },
    });
    if (!channel) {
      client.emit('channel:error', {
        channelId: payload.channelId,
        error: 'Канал не найден',
      });
      return;
    }
    const member = await this.prisma.serverMember.findUnique({
      where: {
        serverId_userId: { serverId: channel.serverId, userId },
      },
    });
    const permissions = channel.permissions;
    const hidden =
      permissions &&
      typeof permissions === 'object' &&
      !Array.isArray(permissions) &&
      (permissions as { canView?: boolean }).canView === false;
    if (
      !member ||
      (client.data as { userId?: string }).userId !== userId ||
      (hidden && channel.server.ownerId !== userId)
    ) {
      client.emit('channel:error', {
        channelId: payload.channelId,
        error: 'Нет доступа к каналу',
      });
      return;
    }

    await client.join(this.getChannelRoom(payload.channelId));
  }

  @SubscribeMessage('channel:leave')
  async leaveChannel(
    @MessageBody() payload: { channelId?: string },
    @ConnectedSocket() client: Socket,
  ) {
    if (typeof payload?.channelId !== 'string') {
      return;
    }

    await client.leave(this.getChannelRoom(payload.channelId));
  }

  emitMessageNew(channelId: string, message: unknown) {
    this.server.to(this.getChannelRoom(channelId)).emit('message:new', message);
  }

  emitMessageUpdate(channelId: string, message: unknown) {
    this.server
      .to(this.getChannelRoom(channelId))
      .emit('message:update', message);
  }

  emitMessageDelete(channelId: string, message: unknown) {
    this.server
      .to(this.getChannelRoom(channelId))
      .emit('message:delete', message);
  }

  private getChannelRoom(channelId: string) {
    return `channel:${channelId}`;
  }
}
