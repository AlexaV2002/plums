import {
  Ack,
  ConnectedSocket,
  MessageBody,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';
import { withChannelRoomLock } from '../channels/channels.gateway';
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
    @Ack()
    ack?: (result: {
      joined: boolean;
      channelId?: string;
      reason?: string;
    }) => void,
  ) {
    const identity = getActiveSocketIdentity(client);
    if (typeof payload?.channelId !== 'string' || !identity) {
      ack?.({ joined: false, reason: 'session_required' });
      return;
    }
    const channelId = payload.channelId;

    const channel = await this.prisma.channel.findUnique({
      where: { id: channelId },
      include: { server: true },
    });
    if (!channel) {
      client.emit('channel:error', {
        channelId,
        error: 'Канал не найден',
      });
      ack?.({
        joined: false,
        channelId,
        reason: 'not_found',
      });
      return;
    }

    // Delete holds the same lock through DB removal and room eviction. A join
    // that read the channel just before deletion must recheck it under the lock.
    await withChannelRoomLock(channelId, async () => {
      if (!isSocketIdentityCurrent(client, identity)) {
        ack?.({ joined: false, reason: 'session_required' });
        return;
      }
      const current = await this.prisma.channel.findUnique({
        where: { id: channelId },
        include: { server: true },
      });
      if (!current) {
        client.emit('channel:error', {
          channelId,
          error: 'Канал не найден',
        });
        ack?.({ joined: false, channelId, reason: 'not_found' });
        return;
      }
      const member = await this.prisma.serverMember.findUnique({
        where: {
          serverId_userId: {
            serverId: current.serverId,
            userId: identity.userId,
          },
        },
      });
      const permissions = current.permissions;
      const hidden =
        permissions &&
        typeof permissions === 'object' &&
        !Array.isArray(permissions) &&
        (permissions as { canView?: boolean }).canView === false;
      if (!member || (hidden && current.server.ownerId !== identity.userId)) {
        if (!isSocketIdentityCurrent(client, identity)) {
          ack?.({ joined: false, reason: 'session_required' });
          return;
        }
        client.emit('channel:error', {
          channelId,
          error: 'Нет доступа к каналу',
        });
        ack?.({ joined: false, channelId, reason: 'forbidden' });
        return;
      }

      if (!isSocketIdentityCurrent(client, identity)) {
        ack?.({ joined: false, reason: 'session_required' });
        return;
      }
      await joinProtectedRoom(client, this.getChannelRoom(channelId), identity);
      if (!isSocketIdentityCurrent(client, identity)) {
        ack?.({ joined: false, reason: 'session_required' });
        return;
      }
      ack?.({ joined: true, channelId });
    });
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
