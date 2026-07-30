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
  reason: 'leave' | 'kick' | 'ban';
};

export type MemberJoinPayload = {
  id: string;
  serverId: string;
  userId: string;
  joinedAt: Date;
  user: {
    id: string;
    username: string;
    email: string;
    avatarUrl: string | null;
    status: string;
    bio: string | null;
  };
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

  emitMemberJoin(payload: MemberJoinPayload) {
    this.server.to(this.getServerRoom(payload.serverId)).emit('member:join', payload);
  }

  private getServerRoom(serverId: string) {
    return `server:${serverId}`;
  }
}
