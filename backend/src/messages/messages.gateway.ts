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
export class MessagesGateway {
  @WebSocketServer()
  server!: Server;

  @SubscribeMessage('channel:join')
  joinChannel(
    @MessageBody() payload: { channelId?: string },
    @ConnectedSocket() client: Socket,
  ) {
    if (!payload.channelId) {
      return;
    }

    client.join(this.getChannelRoom(payload.channelId));
  }

  @SubscribeMessage('channel:leave')
  leaveChannel(
    @MessageBody() payload: { channelId?: string },
    @ConnectedSocket() client: Socket,
  ) {
    if (!payload.channelId) {
      return;
    }

    client.leave(this.getChannelRoom(payload.channelId));
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
