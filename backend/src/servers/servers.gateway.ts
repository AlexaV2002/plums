import {
  ConnectedSocket,
  MessageBody,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';

export type MemberLeavePayload = {
  serverId: string;
  userId: string;
  memberId: string;
  reason: 'leave' | 'kick';
};

@WebSocketGateway({
  cors: {
    origin: '*',
  },
})
export class ServersGateway {
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

  emitMemberLeave(payload: MemberLeavePayload) {
    this.server.to(this.getServerRoom(payload.serverId)).emit('member:leave', payload);
  }

  private getServerRoom(serverId: string) {
    return `server:${serverId}`;
  }
}
