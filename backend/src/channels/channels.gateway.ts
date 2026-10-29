import { WebSocketGateway, WebSocketServer } from '@nestjs/websockets';
import { Server } from 'socket.io';
import { PrismaService } from '../prisma/prisma.service';

type ChannelEvent = 'channel:new' | 'channel:update' | 'channel:delete';

@WebSocketGateway({
  cors: {
    origin: '*',
  },
})
export class ChannelsGateway {
  @WebSocketServer()
  server!: Server;

  constructor(private readonly prisma: PrismaService) {}

  async emitChannelNew(serverId: string, channel: unknown, hidden = false) {
    await this.emitChannelEvent(serverId, 'channel:new', channel, hidden);
  }

  async emitChannelUpdate(
    serverId: string,
    channel: unknown,
    hidden = false,
  ) {
    await this.emitChannelEvent(serverId, 'channel:update', channel, hidden);
  }

  async emitChannelDelete(
    serverId: string,
    channel: unknown,
    hidden = false,
  ) {
    await this.emitChannelEvent(serverId, 'channel:delete', channel, hidden);
  }

  async evictChannelViewers(channelId: string, ownerId: string) {
    const room = `channel:${channelId}`;
    for (const socket of await this.server.in(room).fetchSockets()) {
      if ((socket.data as { userId?: string }).userId !== ownerId)
        socket.leave(room);
    }
  }

  // Участник мог уже загрузить видимый канал. При скрытии отправляем только
  // ранее известный id, чтобы клиент убрал его и сообщения из локального UI.
  async notifyChannelHidden(serverId: string, channelId: string, ownerId: string) {
    const payload = { id: channelId, serverId };
    for (const socket of await this.server.in(this.getServerRoom(serverId)).fetchSockets()) {
      if ((socket.data as { userId?: string }).userId !== ownerId) {
        socket.emit('channel:delete', payload);
      }
    }
  }

  evictChannel(channelId: string) {
    const room = `channel:${channelId}`;
    this.server.in(room).socketsLeave(room);
  }

  // Видимый канал транслируется всем участникам серверной комнаты как раньше.
  // Скрытый канал (canView: false) не должен раскрывать своё существование
  // или метаданные никому, кроме владельца сервера — таким участникам
  // событие отправляется точечно, в обход комнаты server:<id>.
  private async emitChannelEvent(
    serverId: string,
    event: ChannelEvent,
    channel: unknown,
    hidden: boolean,
  ) {
    const room = this.getServerRoom(serverId);

    if (!hidden) {
      this.server.to(room).emit(event, channel);
      return;
    }

    const server = await this.prisma.server.findUnique({
      where: { id: serverId },
      select: { ownerId: true },
    });
    if (!server) return;

    for (const socket of await this.server.in(room).fetchSockets()) {
      if ((socket.data as { userId?: string }).userId === server.ownerId) {
        socket.emit(event, channel);
      }
    }
  }

  private getServerRoom(serverId: string) {
    return `server:${serverId}`;
  }
}
