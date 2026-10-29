import {
  Ack,
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
    @Ack() ack?: (result: { joined: boolean; channelId?: string; reason?: string }) => void,
  ) {
    const identity = getActiveSocketIdentity(client);
    if (typeof payload?.channelId !== 'string' || !identity) {
      ack?.({ joined: false, reason: 'session_required' });
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
      ack?.({ joined: false, channelId: payload.channelId, reason: 'not_found' });
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
      if (!isSocketIdentityCurrent(client, identity)) {
        ack?.({ joined: false, reason: 'session_required' });
        return;
      }
      client.emit('channel:error', {
        channelId: payload.channelId,
        error: 'Нет доступа к каналу',
      });
      ack?.({ joined: false, channelId: payload.channelId, reason: 'forbidden' });
      return;
    }

    if (!isSocketIdentityCurrent(client, identity)) {
      ack?.({ joined: false, reason: 'session_required' });
      return;
    }
    const room = this.getChannelRoom(payload.channelId);
    await joinProtectedRoom(client, room, identity);
    if (!isSocketIdentityCurrent(client, identity)) {
      ack?.({ joined: false, reason: 'session_required' });
      return;
    }
    ack?.({ joined: true, channelId: payload.channelId });
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
