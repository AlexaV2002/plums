import './ensure-test-database';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { App } from 'supertest/types';
import { AddressInfo } from 'net';
import { AppModule } from '../src/app.module';
import { PrismaService } from '../src/prisma/prisma.service';
import { ServersGateway } from '../src/servers/servers.gateway';

// Minimal Engine.IO/Socket.IO probe, mirrors backend/test/realtime-access.e2e-spec.ts
// and backend/test/channel-visibility.e2e-spec.ts.
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

  close() {
    this.socket.close();
  }
}

type Message = { id: string; content: string; createdAt: string };

describe('message reconnect sync via after-cursor (e2e)', () => {
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

  const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

  async function user(label: string) {
    const email = `msync-${label}-${Date.now()}-${Math.random().toString(36).slice(2)}@plums.test`;
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

  async function setupServerAndChannel(owner: { token: string }, member: { token: string }) {
    const server = await request(app.getHttpServer())
      .post('/servers')
      .set(auth(owner.token))
      .send({ name: 'Reconnect sync smoke' })
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

    return { serverId, channelId };
  }

  async function connectAndJoin(token: string, userId: string, serverId: string, channelId: string) {
    const socket = await SocketProbe.connect(port);
    probes.push(socket);
    await socket.identify(token);
    socket.emit('server:join', { serverId });
    socket.emit('channel:join', { channelId });
    await waitForRoom(`server:${serverId}`, userId, true);
    await waitForRoom(`channel:${channelId}`, userId, true);
    return socket;
  }

  async function postMessagesSequentially(
    token: string,
    channelId: string,
    count: number,
    prefix: string,
  ) {
    // Sequential (awaited) posts guarantee strictly increasing createdAt,
    // because Message.id is a random UUID (not time-sortable) and createdAt
    // has microsecond resolution: parallel inserts could tie on createdAt
    // and let the composite cursor's id-tiebreak reorder messages.
    const ids: string[] = [];
    for (let i = 1; i <= count; i++) {
      const content = `${prefix}-${String(i).padStart(3, '0')}`;
      const res = await request(app.getHttpServer())
        .post(`/channels/${channelId}/messages`)
        .set(auth(token))
        .send({ content })
        .expect(201);
      ids.push((res.body as Message).id);
    }
    return ids;
  }

  async function fetchAllAfter(token: string, channelId: string, afterCursor: string) {
    const collected: Message[] = [];
    let cursor = afterCursor;
    for (let guard = 0; guard < 50; guard++) {
      const res = await request(app.getHttpServer())
        .get(`/channels/${channelId}/messages`)
        .query({ after: cursor, limit: 50 })
        .set(auth(token))
        .expect(200);
      const page = res.body as Message[];
      collected.push(...page);
      if (page.length < 50) break;
      cursor = page[page.length - 1].id;
    }
    return collected;
  }

  it.each([50, 51, 60, 120])(
    'reconnecting client B catches up exactly %d messages missed while offline, in order, no dupes/gaps',
    async (count) => {
      const owner = await user(`owner-${count}`);
      const member = await user(`member-${count}`);
      const { serverId, channelId } = await setupServerAndChannel(owner, member);

      await connectAndJoin(owner.token, owner.id, serverId, channelId);
      const memberSocket = await connectAndJoin(member.token, member.id, serverId, channelId);

      // B establishes a "last known message" cursor before dropping.
      const seed = await request(app.getHttpServer())
        .post(`/channels/${channelId}/messages`)
        .set(auth(owner.token))
        .send({ content: 'SEED' })
        .expect(201);
      const lastKnownId = (seed.body as Message).id;

      // B loses connection; A stays connected and keeps sending.
      memberSocket.close();
      probes.splice(probes.indexOf(memberSocket), 1);

      const prefix = `TEST-${count}`;
      const sentIds = await postMessagesSequentially(owner.token, channelId, count, prefix);

      // B reconnects.
      await connectAndJoin(member.token, member.id, serverId, channelId);

      const caughtUp = await fetchAllAfter(member.token, channelId, lastKnownId);

      expect(caughtUp.map((m) => m.id)).toEqual(sentIds);
      expect(caughtUp.map((m) => m.content)).toEqual(
        sentIds.map((_, i) => `${prefix}-${String(i + 1).padStart(3, '0')}`),
      );
    },
    20000,
  );

  it('after-cursor pointing at a since soft-deleted message still resolves and returns later messages', async () => {
    const owner = await user('owner-soft');
    const member = await user('member-soft');
    const { serverId, channelId } = await setupServerAndChannel(owner, member);

    await connectAndJoin(owner.token, owner.id, serverId, channelId);
    const memberSocket = await connectAndJoin(member.token, member.id, serverId, channelId);

    const cursorMessage = await request(app.getHttpServer())
      .post(`/channels/${channelId}/messages`)
      .set(auth(owner.token))
      .send({ content: 'TO-BE-DELETED' })
      .expect(201);
    const cursorId = (cursorMessage.body as Message).id;

    memberSocket.close();
    probes.splice(probes.indexOf(memberSocket), 1);

    const after = await request(app.getHttpServer())
      .post(`/channels/${channelId}/messages`)
      .set(auth(owner.token))
      .send({ content: 'AFTER-DELETE' })
      .expect(201);

    // Author soft-deletes the cursor message while B is offline.
    await request(app.getHttpServer())
      .delete(`/messages/${cursorId}`)
      .set(auth(owner.token))
      .expect(200);

    await connectAndJoin(member.token, member.id, serverId, channelId);

    const page = await request(app.getHttpServer())
      .get(`/channels/${channelId}/messages`)
      .query({ after: cursorId, limit: 50 })
      .set(auth(member.token))
      .expect(200);

    expect((page.body as Message[]).map((m) => m.id)).toEqual([
      (after.body as Message).id,
    ]);
  }, 15000);

  it('after-cursor pointing into a since fully-deleted channel deterministically 404s instead of hanging', async () => {
    const owner = await user('owner-hard');
    const member = await user('member-hard');
    const { serverId, channelId } = await setupServerAndChannel(owner, member);

    await connectAndJoin(owner.token, owner.id, serverId, channelId);
    const memberSocket = await connectAndJoin(member.token, member.id, serverId, channelId);

    const cursorMessage = await request(app.getHttpServer())
      .post(`/channels/${channelId}/messages`)
      .set(auth(owner.token))
      .send({ content: 'CURSOR' })
      .expect(201);
    const cursorId = (cursorMessage.body as Message).id;

    memberSocket.close();
    probes.splice(probes.indexOf(memberSocket), 1);

    // Channel (and, via cascade, every message in it, including the cursor)
    // is deleted entirely while B is offline.
    await request(app.getHttpServer())
      .delete(`/channels/${channelId}`)
      .set(auth(owner.token))
      .expect(200);

    await request(app.getHttpServer())
      .get(`/channels/${channelId}/messages`)
      .query({ after: cursorId, limit: 50 })
      .set(auth(member.token))
      .expect(404);
  }, 15000);
});
