import {
  ConnectedSocket,
  MessageBody,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';

@WebSocketGateway({
  cors: {
    origin: '*',
  },
})
export class ChannelsGateway {
  @WebSocketServer()
  server!: Server;

  @SubscribeMessage('server:join')
  joinServer(
    @MessageBody() payload: { serverId?: string },
    @ConnectedSocket() client: Socket,
  ) {
    if (!payload.serverId) {
      return;
    }

    client.join(this.getServerRoom(payload.serverId));
  }

  @SubscribeMessage('server:leave')
  leaveServer(
    @MessageBody() payload: { serverId?: string },
    @ConnectedSocket() client: Socket,
  ) {
    if (!payload.serverId) {
      return;
    }

    client.leave(this.getServerRoom(payload.serverId));
  }

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

  private getServerRoom(serverId: string) {
    return `server:${serverId}`;
  }
}
