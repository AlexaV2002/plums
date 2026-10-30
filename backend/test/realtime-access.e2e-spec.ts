import './ensure-test-database';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { App } from 'supertest/types';
import { AddressInfo } from 'net';
import { AppModule } from '../src/app.module';
import { PrismaService } from '../src/prisma/prisma.service';
import { ServersGateway } from '../src/servers/servers.gateway';

// Small Engine.IO/Socket.IO probe: exercises the real gateway without adding
// a second client dependency to the backend.
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

  async event(name: string) {
    const packet = await this.waitPacket((item) => {
      if (!item.startsWith('42')) return false;
      const parsed = JSON.parse(item.slice(2)) as [string, unknown];
      return parsed[0] === name;
    });
    return (JSON.parse(packet.slice(2)) as [string, unknown])[1];
  }

  async expectNoEvent(name: string) {
    await expect(
      this.waitPacket((item) => {
        if (!item.startsWith('42')) return false;
        return (JSON.parse(item.slice(2)) as [string, unknown])[0] === name;
      }, 200),
    ).rejects.toThrow('Socket.IO packet timeout');
  }

  close() {
    this.socket.close();
  }
}

describe('realtime access (e2e)', () => {
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
    // Disconnect handlers write OFFLINE asynchronously. Keep users until they finish.
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
    const email = `realtime-${label}-${Date.now()}-${Math.random().toString(36).slice(2)}@plums.test`;
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
    return {
      id: registeredBody.user.id,
      token: loggedInBody.accessToken,
    };
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

  it('rejects strangers, restores rooms, and evicts users after access changes', async () => {
    const owner = await user('owner');
    const member = await user('member');
    const auth = (token: string) => ({ Authorization: `Bearer ${token}` });
    const server = await request(app.getHttpServer())
      .post('/servers')
      .set(auth(owner.token))
      .send({ name: 'Realtime smoke' })
      .expect(201);
    const serverId = (server.body as { id: string }).id;
    const channel = await request(app.getHttpServer())
      .post(`/servers/${serverId}/channels`)
      .set(auth(owner.token))
      .send({ name: 'general' })
      .expect(201);
    const channelId = (channel.body as { id: string }).id;
    const memberSocket = await SocketProbe.connect(port);
    probes.push(memberSocket);

    memberSocket.emit('server:join', { serverId });
    await waitForRoom(`server:${serverId}`, member.id, false);
    expect((await memberSocket.identify(member.token))[0].userId).toBe(
      member.id,
    );
    memberSocket.emit('server:join', { serverId });
    expect(await memberSocket.event('server:error')).toMatchObject({
      serverId,
    });
    memberSocket.emit('channel:join', { channelId });
    expect(await memberSocket.event('channel:error')).toMatchObject({
      channelId,
    });

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
    memberSocket.emit('server:join', { serverId });
    memberSocket.emit('channel:join', { channelId });
    await waitForRoom(`server:${serverId}`, member.id, true);
    await waitForRoom(`channel:${channelId}`, member.id, true);

    const message = await request(app.getHttpServer())
      .post(`/channels/${channelId}/messages`)
      .set(auth(owner.token))
      .send({ content: 'first' })
      .expect(201);
    expect(await memberSocket.event('message:new')).toMatchObject({
      id: (message.body as { id: string }).id,
    });

    await request(app.getHttpServer())
      .patch(`/channels/${channelId}/permissions`)
      .set(auth(owner.token))
      .send({ canView: false })
      .expect(200);
    await waitForRoom(`channel:${channelId}`, member.id, false);
    memberSocket.emit('channel:join', { channelId });
    expect(await memberSocket.event('channel:error')).toMatchObject({
      channelId,
    });

    await request(app.getHttpServer())
      .patch(`/channels/${channelId}/permissions`)
      .set(auth(owner.token))
      .send({ canView: true })
      .expect(200);
    memberSocket.emit('channel:join', { channelId });
    await waitForRoom(`channel:${channelId}`, member.id, true);

    // A fresh transport proves that membership checks still work on reconnect.
    memberSocket.close();
    const reconnected = await SocketProbe.connect(port);
    probes.push(reconnected);
    expect((await reconnected.identify(member.token))[0].userId).toBe(
      member.id,
    );
    reconnected.emit('server:join', { serverId });
    reconnected.emit('channel:join', { channelId });
    await waitForRoom(`channel:${channelId}`, member.id, true);

    const membership = await prisma.serverMember.findUniqueOrThrow({
      where: { serverId_userId: { serverId, userId: member.id } },
    });
    await request(app.getHttpServer())
      .delete(`/servers/${serverId}/members/${membership.id}`)
      .set(auth(owner.token))
      .expect(200);
    await waitForRoom(`server:${serverId}`, member.id, false);
    await waitForRoom(`channel:${channelId}`, member.id, false);
    reconnected.emit('server:join', { serverId });
    expect(await reconnected.event('server:error')).toMatchObject({ serverId });
  }, 30000);

  it('evicts a banned member and rejects joins after reconnect', async () => {
    const owner = await user('ban-owner');
    const member = await user('ban-member');
    const auth = (token: string) => ({ Authorization: `Bearer ${token}` });
    const server = await request(app.getHttpServer())
      .post('/servers')
      .set(auth(owner.token))
      .send({ name: 'Ban smoke' })
      .expect(201);
    const serverId = (server.body as { id: string }).id;
    const channel = await request(app.getHttpServer())
      .post(`/servers/${serverId}/channels`)
      .set(auth(owner.token))
      .send({ name: 'general' })
      .expect(201);
    const channelId = (channel.body as { id: string }).id;
    await prisma.serverMember.create({
      data: { serverId, userId: member.id },
    });

    const socket = await SocketProbe.connect(port);
    probes.push(socket);
    await socket.identify(member.token);
    socket.emit('server:join', { serverId });
    socket.emit('channel:join', { channelId });
    await waitForRoom(`server:${serverId}`, member.id, true);
    await waitForRoom(`channel:${channelId}`, member.id, true);

    await request(app.getHttpServer())
      .post(`/servers/${serverId}/bans/${member.id}`)
      .set(auth(owner.token))
      .send({ reason: 'test' })
      .expect(201);
    await waitForRoom(`server:${serverId}`, member.id, false);
    await waitForRoom(`channel:${channelId}`, member.id, false);

    socket.emit('server:join', { serverId });
    expect(await socket.event('server:error')).toMatchObject({ serverId });
    socket.emit('channel:join', { channelId });
    expect(await socket.event('channel:error')).toMatchObject({ channelId });

    socket.close();
    const reconnected = await SocketProbe.connect(port);
    probes.push(reconnected);
    await reconnected.identify(member.token);
    reconnected.emit('server:join', { serverId });
    expect(await reconnected.event('server:error')).toMatchObject({ serverId });
    reconnected.emit('channel:join', { channelId });
    expect(await reconnected.event('channel:error')).toMatchObject({
      channelId,
    });

    await request(app.getHttpServer())
      .post(`/channels/${channelId}/messages`)
      .set(auth(owner.token))
      .send({ content: 'after ban' })
      .expect(201);
    await reconnected.expectNoEvent('message:new');
  }, 30000);

  it('keeps email private in member, message, ban and realtime payloads', async () => {
    const owner = await user('privacy-owner');
    const member = await user('privacy-member');
    const auth = (token: string) => ({ Authorization: `Bearer ${token}` });
    const server = await request(app.getHttpServer())
      .post('/servers')
      .set(auth(owner.token))
      .send({ name: 'Privacy smoke' })
      .expect(201);
    const serverId = (server.body as { id: string }).id;
    const channel = await request(app.getHttpServer())
      .post(`/servers/${serverId}/channels`)
      .set(auth(owner.token))
      .send({ name: 'general' })
      .expect(201);
    const channelId = (channel.body as { id: string }).id;
    await prisma.serverMember.create({ data: { serverId, userId: member.id } });

    const detail = await request(app.getHttpServer())
      .get(`/servers/${serverId}`)
      .set(auth(owner.token))
      .expect(200);
    const members = await request(app.getHttpServer())
      .get(`/servers/${serverId}/members`)
      .set(auth(owner.token))
      .expect(200);
    expect(
      (detail.body as { members: Array<{ user: object }> }).members[0].user,
    ).not.toHaveProperty('email');
    expect(
      (members.body as Array<{ user: object }>)[0].user,
    ).not.toHaveProperty('email');

    const socket = await SocketProbe.connect(port);
    probes.push(socket);
    await socket.identify(member.token);
    socket.emit('channel:join', { channelId });
    await waitForRoom(`channel:${channelId}`, member.id, true);
    const sent = await request(app.getHttpServer())
      .post(`/channels/${channelId}/messages`)
      .set(auth(owner.token))
      .send({ content: 'private author data' })
      .expect(201);
    expect((sent.body as { author: object }).author).not.toHaveProperty(
      'email',
    );
    const realtime = (await socket.event('message:new')) as { author: object };
    expect(realtime.author).not.toHaveProperty('email');

    const me = await request(app.getHttpServer())
      .get('/users/me')
      .set(auth(owner.token))
      .expect(200);
    expect(me.body).toHaveProperty('email');
    await request(app.getHttpServer())
      .post(`/servers/${serverId}/bans/${member.id}`)
      .set(auth(owner.token))
      .send({ reason: 'privacy test' })
      .expect(201);
    const bans = await request(app.getHttpServer())
      .get(`/servers/${serverId}/bans`)
      .set(auth(owner.token))
      .expect(200);
    expect((bans.body as Array<{ user: object }>)[0].user).not.toHaveProperty(
      'email',
    );
  }, 30000);
});
