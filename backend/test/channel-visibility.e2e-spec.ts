import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { App } from 'supertest/types';
import { AddressInfo } from 'net';
import { AppModule } from '../src/app.module';
import { PrismaService } from '../src/prisma/prisma.service';
import { ServersGateway } from '../src/servers/servers.gateway';

// Minimal Engine.IO/Socket.IO probe, mirrors backend/test/realtime-access.e2e-spec.ts.
class SocketProbe {
  private readonly socket: WebSocket;
  private readonly packets: string[] = [];
  private readonly waiters: Array<{
    match: (packet: string) => boolean;
    done: (packet: string) => void;
  }> = [];

  private constructor(port: number) {
    this.socket = new WebSocket(
      `ws://127.0.0.1:${port}/socket.io/?EIO=4&transport=websocket`,
    );
    this.socket.addEventListener('message', (event) => {
      const packet = String(event.data);
      if (packet === '2') {
        this.socket.send('3');
        return;
      }
      const index = this.waiters.findIndex((waiter) => waiter.match(packet));
      if (index >= 0) this.waiters.splice(index, 1)[0].done(packet);
      else this.packets.push(packet);
    });
  }

  static async connect(port: number) {
    const probe = new SocketProbe(port);
    await probe.waitPacket((packet) => packet.startsWith('0'));
    probe.socket.send('40');
    await probe.waitPacket((packet) => packet.startsWith('40'));
    return probe;
  }

  private waitPacket(match: (packet: string) => boolean, timeoutMs = 5000) {
    const queuedIndex = this.packets.findIndex(match);
    if (queuedIndex >= 0)
      return Promise.resolve(this.packets.splice(queuedIndex, 1)[0]);
    return new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.splice(this.waiters.indexOf(waiter), 1);
        reject(new Error('Socket.IO packet timeout'));
      }, timeoutMs);
      const waiter = {
        match,
        done: (packet: string) => {
          clearTimeout(timer);
          resolve(packet);
        },
      };
      this.waiters.push(waiter);
    });
  }

  async identify(token: string) {
    this.socket.send(`421${JSON.stringify(['presence:identify', { token }])}`);
    const ack = await this.waitPacket((packet) => packet.startsWith('431'));
    return JSON.parse(ack.slice(3)) as Array<{ userId: string }>;
  }

  emit(name: string, payload: object) {
    this.socket.send(`42${JSON.stringify([name, payload])}`);
  }

  async event(name: string, timeoutMs = 5000) {
    const packet = await this.waitPacket((item) => {
      if (!item.startsWith('42')) return false;
      const parsed = JSON.parse(item.slice(2)) as [string, unknown];
      return parsed[0] === name;
    }, timeoutMs);
    return (JSON.parse(packet.slice(2)) as [string, unknown])[1];
  }

  // Positive assertion that an event name is NOT delivered within the window.
  async expectNoEvent(name: string, timeoutMs = 400) {
    await expect(this.event(name, timeoutMs)).rejects.toThrow(
      'Socket.IO packet timeout',
    );
  }

  close() {
    this.socket.close();
  }
}

describe('channel visibility realtime leak (e2e)', () => {
  let app: INestApplication<App>;
  let prisma: PrismaService;
  let gateway: ServersGateway;
  let port: number;
  const userIds: string[] = [];
  const probes: SocketProbe[] = [];

  beforeAll(async () => {
    const module = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();
    app = module.createNestApplication<App>();
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
    );
    await app.listen(0, '127.0.0.1');
    port = (
      app.getHttpServer() as unknown as { address(): AddressInfo }
    ).address().port;
    prisma = app.get(PrismaService);
    gateway = app.get(ServersGateway);
  });

  afterAll(async () => {
    probes.forEach((probe) => probe.close());
    await new Promise((resolve) => setTimeout(resolve, 250));
    if (prisma && userIds.length) {
      for (let attempt = 0; attempt < 50; attempt++) {
        const online = await prisma.user.count({
          where: { id: { in: userIds }, status: 'ONLINE' },
        });
        if (online === 0) break;
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    }
    if (app) await app.close();
  });

  async function user(label: string) {
    const email = `chvis-${label}-${Date.now()}-${Math.random().toString(36).slice(2)}@plums.test`;
    const password = 'SmokeTest-12345';
    const registered = await request(app.getHttpServer())
      .post('/auth/register')
      .send({ username: label, email, password })
      .expect(201);
    const registeredBody = registered.body as { user: { id: string } };
    userIds.push(registeredBody.user.id);
    const loggedIn = await request(app.getHttpServer())
      .post('/auth/login')
      .send({ email, password })
      .expect(201);
    const loggedInBody = loggedIn.body as { accessToken: string };
    return { id: registeredBody.user.id, token: loggedInBody.accessToken };
  }

  async function waitForRoom(room: string, userId: string, present: boolean) {
    for (let attempt = 0; attempt < 100; attempt++) {
      const sockets = await gateway.server.in(room).fetchSockets();
      if (
        sockets.some(
          (socket) => (socket.data as { userId?: string }).userId === userId,
        ) === present
      )
        return;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    throw new Error(`Room ${room}: user ${userId} presence was not ${present}`);
  }

  it('does not leak hidden channel events to non-owners and stops leaking to evicted/kicked members', async () => {
    const owner = await user('owner');
    const member = await user('member');
    const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

    const server = await request(app.getHttpServer())
      .post('/servers')
      .set(auth(owner.token))
      .send({ name: 'Visibility smoke' })
      .expect(201);
    const serverId = (server.body as { id: string }).id;

    const channel = await request(app.getHttpServer())
      .post(`/servers/${serverId}/channels`)
      .set(auth(owner.token))
      .send({ name: 'general' })
      .expect(201);
    const channelId = (channel.body as { id: string }).id;

    const invite = await request(app.getHttpServer())
      .post(`/servers/${serverId}/invites`)
      .set(auth(owner.token))
      .send({})
      .expect(201);
    await request(app.getHttpServer())
      .post(`/invites/${(invite.body as { code: string }).code}/join`)
      .set(auth(member.token))
      .send({})
      .expect(201);

    const ownerSocket = await SocketProbe.connect(port);
    probes.push(ownerSocket);
    await ownerSocket.identify(owner.token);
    ownerSocket.emit('server:join', { serverId });
    await waitForRoom(`server:${serverId}`, owner.id, true);

    const memberSocket = await SocketProbe.connect(port);
    probes.push(memberSocket);
    await memberSocket.identify(member.token);
    memberSocket.emit('server:join', { serverId });
    memberSocket.emit('channel:join', { channelId });
    await waitForRoom(`server:${serverId}`, member.id, true);
    await waitForRoom(`channel:${channelId}`, member.id, true);

    // Hide the channel: owner must still learn about it, the member must not.
    await request(app.getHttpServer())
      .patch(`/channels/${channelId}/permissions`)
      .set(auth(owner.token))
      .send({ canView: false })
      .expect(200);
    expect(await ownerSocket.event('channel:update')).toMatchObject({
      id: channelId,
    });
    await memberSocket.expectNoEvent('channel:update');

    // Member can no longer see or (re)join the now-hidden channel.
    const listAsMember = await request(app.getHttpServer())
      .get(`/servers/${serverId}/channels`)
      .set(auth(member.token))
      .expect(200);
    expect(
      (listAsMember.body as Array<{ id: string }>).some(
        (item) => item.id === channelId,
      ),
    ).toBe(false);
    memberSocket.emit('channel:join', { channelId });
    expect(await memberSocket.event('channel:error')).toMatchObject({
      channelId,
    });

    // Renaming the still-hidden channel must keep leaking only to the owner.
    await request(app.getHttpServer())
      .patch(`/channels/${channelId}`)
      .set(auth(owner.token))
      .send({ name: 'renamed-hidden' })
      .expect(200);
    expect(await ownerSocket.event('channel:update')).toMatchObject({
      id: channelId,
      name: 'renamed-hidden',
    });
    await memberSocket.expectNoEvent('channel:update');

    // Deleting the still-hidden channel must keep leaking only to the owner.
    await request(app.getHttpServer())
      .delete(`/channels/${channelId}`)
      .set(auth(owner.token))
      .expect(200);
    expect(await ownerSocket.event('channel:delete')).toMatchObject({
      id: channelId,
    });
    await memberSocket.expectNoEvent('channel:delete');

    // A visible channel to confirm kicked members stop receiving any channel
    // events at all, hidden or not, once removed from the server room.
    const visibleChannel = await request(app.getHttpServer())
      .post(`/servers/${serverId}/channels`)
      .set(auth(owner.token))
      .send({ name: 'lobby' })
      .expect(201);
    expect(await memberSocket.event('channel:new')).toMatchObject({
      id: (visibleChannel.body as { id: string }).id,
    });

    const membership = await prisma.serverMember.findUniqueOrThrow({
      where: { serverId_userId: { serverId, userId: member.id } },
    });
    await request(app.getHttpServer())
      .delete(`/servers/${serverId}/members/${membership.id}`)
      .set(auth(owner.token))
      .expect(200);
    await waitForRoom(`server:${serverId}`, member.id, false);

    await request(app.getHttpServer())
      .patch(`/channels/${(visibleChannel.body as { id: string }).id}`)
      .set(auth(owner.token))
      .send({ name: 'lobby-renamed' })
      .expect(200);
    expect(await ownerSocket.event('channel:update')).toMatchObject({
      name: 'lobby-renamed',
    });
    await memberSocket.expectNoEvent('channel:update');
  }, 30000);
});
