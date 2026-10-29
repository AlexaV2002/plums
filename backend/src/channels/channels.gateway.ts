import { WebSocketGateway, WebSocketServer } from '@nestjs/websockets';
import { Server } from 'socket.io';

@WebSocketGateway({
  cors: {
    origin: '*',
  },
})
export class ChannelsGateway {
  @WebSocketServer()
  server!: Server;

  emitChannelNew(serverId: string, channel: unknown) {
    this.server.to(this.getServerRoom(serverId)).emit('channel:new', channel);
  }

  emitChannelUpdate(serverId: string, channel: unknown) {
    this.server
      .to(this.getServerRoom(serverId))
      .emit('channel:update', channel);
  }

  emitChannelDelete(serverId: string, channel: unknown) {
    this.server
      .to(this.getServerRoom(serverId))
      .emit('channel:delete', channel);
  }

  async evictChannelViewers(channelId: string, ownerId: string) {
    const room = `channel:${channelId}`;
    for (const socket of await this.server.in(room).fetchSockets()) {
      if ((socket.data as { userId?: string }).userId !== ownerId)
        socket.leave(room);
    }
  }

  evictChannel(channelId: string) {
    const room = `channel:${channelId}`;
    this.server.in(room).socketsLeave(room);
  }

  private getServerRoom(serverId: string) {
    return `server:${serverId}`;
  }
}
