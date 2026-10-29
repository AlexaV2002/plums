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
    const identity = getActiveSocketIdentity(client);
    if (typeof payload?.channelId !== 'string' || !identity) {
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
        serverId_userId: {
          serverId: channel.serverId,
          userId: identity.userId,
        },
      },
    });
    const permissions = channel.permissions;
    const hidden =
      permissions &&
      typeof permissions === 'object' &&
      !Array.isArray(permissions) &&
      (permissions as { canView?: boolean }).canView === false;
    if (!member || (hidden && channel.server.ownerId !== identity.userId)) {
      if (!isSocketIdentityCurrent(client, identity)) return;
      client.emit('channel:error', {
        channelId: payload.channelId,
        error: 'Нет доступа к каналу',
      });
      return;
    }

    if (!isSocketIdentityCurrent(client, identity)) return;
    const room = this.getChannelRoom(payload.channelId);
    await joinProtectedRoom(client, room, identity);
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
