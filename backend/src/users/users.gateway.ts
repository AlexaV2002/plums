import {
  ConnectedSocket,
  MessageBody,
  OnGatewayConnection,
  OnGatewayDisconnect,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
} from '@nestjs/websockets';
import { JwtService } from '@nestjs/jwt';
import { Server, Socket } from 'socket.io';
import { PrismaService } from '../prisma/prisma.service';

type JwtPayload = {
  sub: string;
  email: string;
};

type UserStatus = 'ONLINE' | 'OFFLINE' | 'AWAY' | 'DO_NOT_DISTURB';

@WebSocketGateway({
  cors: {
    origin: '*',
  },
})
export class UsersGateway
  implements OnGatewayConnection, OnGatewayDisconnect
{
  @WebSocketServer()
  server!: Server;

  private readonly connectionsByUser = new Map<string, number>();

  constructor(
    private readonly jwtService: JwtService,
    private readonly prisma: PrismaService,
  ) {}

  handleConnection() {
    return;
  }

  @SubscribeMessage('presence:identify')
  async identify(
    @MessageBody() payload: { token?: string },
    @ConnectedSocket() client: Socket,
  ) {
    const userId = await this.getUserIdFromToken(payload.token);

    if (!userId) {
      client.disconnect(true);
      return;
    }

    if (client.data.userId === userId) {
      return;
    }

    client.data.userId = userId;

    const connections = this.connectionsByUser.get(userId) ?? 0;
    this.connectionsByUser.set(userId, connections + 1);

    if (connections === 0) {
      await this.updateAndEmitStatus(userId, 'ONLINE');
    }
  }

  async handleDisconnect(client: Socket) {
    const userId = client.data.userId as string | undefined;

    if (!userId) {
      return;
    }

    const connections = this.connectionsByUser.get(userId) ?? 0;
    const nextConnections = Math.max(connections - 1, 0);

    if (nextConnections > 0) {
      this.connectionsByUser.set(userId, nextConnections);
      return;
    }

    this.connectionsByUser.delete(userId);
    await this.updateAndEmitStatus(userId, 'OFFLINE');
  }

  emitUserStatus(userId: string, status: UserStatus) {
    this.server.emit('user:status', { userId, status });
  }

  private async updateAndEmitStatus(userId: string, status: UserStatus) {
    await this.prisma.user.update({
      where: {
        id: userId,
      },
      data: {
        status,
      },
    });

    this.emitUserStatus(userId, status);
  }

  private async getUserIdFromToken(token?: string) {
    if (!token) {
      return null;
    }

    try {
      const payload = await this.jwtService.verifyAsync<JwtPayload>(token, {
        secret: process.env.JWT_SECRET,
      });

      return payload.sub;
    } catch {
      return null;
    }
  }
}
