import './ensure-test-database';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomUUID } from 'crypto';
import request from 'supertest';
import { App } from 'supertest/types';
import { AddressInfo } from 'net';
import { AppModule } from '../src/app.module';
import { PrismaService } from '../src/prisma/prisma.service';

type DmUser = { id: string; username: string; avatarUrl: string | null };
type DmMessage = {
  id: string;
  conversationId: string;
  senderId: string;
  content: string;
  createdAt: string;
  updatedAt: string;
  sender: DmUser;
};
type DmConversation = {
  id: string;
  createdAt: string;
  updatedAt: string;
  userA: DmUser;
  userB: DmUser;
  lastMessage: DmMessage | null;
};

const conversationKeys = [
  'createdAt',
  'id',
  'lastMessage',
  'updatedAt',
  'userA',
  'userB',
];
const messageKeys = [
  'content',
  'conversationId',
  'createdAt',
  'id',
  'sender',
  'senderId',
  'updatedAt',
];
const userKeys = ['avatarUrl', 'id', 'username'];

// Рекурсивно: ни в одном ответе/событии DM не должно быть ключа email.
function expectNoEmail(value: unknown) {
  if (Array.isArray(value)) {
    value.forEach(expectNoEmail);
    return;
  }
  if (value && typeof value === 'object') {
    expect(value).not.toHaveProperty('email');
    expect(value).not.toHaveProperty('passwordHash');
    Object.values(value).forEach(expectNoEmail);
  }
}

function expectMessageShape(message: DmMessage) {
  expect(Object.keys(message).sort()).toEqual(messageKeys);
  expect(Object.keys(message.sender).sort()).toEqual(userKeys);
}

function expectConversationShape(conversation: DmConversation) {
  expect(Object.keys(conversation).sort()).toEqual(conversationKeys);
  expect(Object.keys(conversation.userA).sort()).toEqual(userKeys);
  expect(Object.keys(conversation.userB).sort()).toEqual(userKeys);
  if (conversation.lastMessage) expectMessageShape(conversation.lastMessage);
}

// Минимальный Engine.IO/Socket.IO-клиент (как в realtime-access.e2e-spec.ts)
// с поддержкой ack: без новой зависимости socket.io-client.
class SocketProbe {
  private readonly socket: WebSocket;
  private readonly packets: string[] = [];
  private readonly waiters: Array<{
    match: (packet: string) => boolean;
    done: (packet: string) => void;
  }> = [];
  private nextAckId = 1;

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

  async request<T>(name: string, payload: object): Promise<T> {
    const id = this.nextAckId++;
    this.socket.send(`42${id}${JSON.stringify([name, payload])}`);
    const ack = await this.waitPacket((packet) => {
      const match = /^43(\d+)\[/.exec(packet);
      return match !== null && Number(match[1]) === id;
    });
    const args = JSON.parse(ack.slice(2 + String(id).length)) as T[];
    return args[0];
  }

  identify(token: string) {
    return this.request<{ userId: string }>('presence:identify', { token });
  }

  joinDm(conversationId: string) {
    return this.request<Record<string, unknown>>('dm:join', {
      conversationId,
    });
  }

  async event<T = unknown>(name: string) {
    const packet = await this.waitPacket((item) => {
      if (!item.startsWith('42')) return false;
      const parsed = JSON.parse(item.slice(2)) as [string, unknown];
      return parsed[0] === name;
    });
    return (JSON.parse(packet.slice(2)) as [string, T])[1];
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

describe('DM contract (e2e)', () => {
  let app: INestApplication<App>;
  let prisma: PrismaService;
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
    // Один listen: иначе supertest на каждый запрос делает listen/close
    // и параллельные запросы получают ECONNRESET.
    await app.listen(0, '127.0.0.1');
    port = (
      app.getHttpServer() as unknown as { address(): AddressInfo }
    ).address().port;
    prisma = app.get(PrismaService);
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

  const auth = (token: string) => ({ Authorization: `Bearer ${token}` });
  const http = () => request(app.getHttpServer());

  async function user(label: string) {
    const email = `dm-${label}-${Date.now()}-${Math.random().toString(36).slice(2)}@plums.test`;
    const password = 'SmokeTest-12345';
    const registered = await http()
      .post('/auth/register')
      .send({ username: label, email, password })
      .expect(201);
    const registeredBody = registered.body as { user: { id: string } };
    userIds.push(registeredBody.user.id);
    const loggedIn = await http()
      .post('/auth/login')
      .send({ email, password })
      .expect(201);
    const loggedInBody = loggedIn.body as { accessToken: string };
    return { id: registeredBody.user.id, token: loggedInBody.accessToken };
  }

  async function connect() {
    const probe = await SocketProbe.connect(port);
    probes.push(probe);
    return probe;
  }

  async function list(token: string) {
    const response = await http()
      .get('/dm/conversations')
      .set(auth(token))
      .expect(200);
    expectNoEmail(response.body);
    return response.body as DmConversation[];
  }

  async function history(token: string, conversationId: string, query = '') {
    const response = await http()
      .get(`/dm/conversations/${conversationId}/messages${query}`)
      .set(auth(token))
      .expect(200);
    expectNoEmail(response.body);
    return response.body as DmMessage[];
  }

  async function send(token: string, conversationId: string, content: string) {
    const response = await http()
      .post(`/dm/conversations/${conversationId}/messages`)
      .set(auth(token))
      .send({ content })
      .expect(201);
    expectNoEmail(response.body);
    expectMessageShape(response.body as DmMessage);
    return response.body as DmMessage;
  }

  it('keeps one contract for conversations, history, realtime and access', async () => {
    const a = await user('dm-a');
    const b = await user('dm-b');
    const c = await user('dm-c');

    // Создание: A->B и B->A дают один диалог одинаковой формы.
    const fromA = await http()
      .post('/dm/conversations')
      .set(auth(a.token))
      .send({ userId: b.id })
      .expect(201);
    const fromB = await http()
      .post('/dm/conversations')
      .set(auth(b.token))
      .send({ userId: a.id })
      .expect(201);
    expectNoEmail(fromA.body);
    expectConversationShape(fromA.body as DmConversation);
    expect(fromB.body).toEqual(fromA.body);
    const conversation = fromA.body as DmConversation;
    const [lowId, highId] = [a.id, b.id].sort();
    expect(conversation.userA.id).toBe(lowId);
    expect(conversation.userB.id).toBe(highId);
    expect(conversation.lastMessage).toBeNull();
    const conversationId = conversation.id;

    await http()
      .post('/dm/conversations')
      .set(auth(a.token))
      .send({ userId: randomUUID() })
      .expect(404);
    await http()
      .post('/dm/conversations')
      .set(auth(a.token))
      .send({ userId: a.id })
      .expect(400);

    // Realtime: identify -> ack -> dm:join -> ack.
    const anonymous = await connect();
    expect(await anonymous.joinDm(conversationId)).toEqual({
      joined: false,
      conversationId,
      reason: 'unidentified',
    });

    const bSocket = await connect();
    expect((await bSocket.identify(b.token)).userId).toBe(b.id);
    expect(await bSocket.joinDm(conversationId)).toEqual({
      joined: true,
      conversationId,
    });

    const cSocket = await connect();
    expect((await cSocket.identify(c.token)).userId).toBe(c.id);
    expect(await cSocket.joinDm(conversationId)).toEqual({
      joined: false,
      conversationId,
      reason: 'forbidden',
    });
    expect(await cSocket.joinDm(randomUUID())).toMatchObject({
      joined: false,
      reason: 'not_found',
    });

    // Отправка: ответ POST и dm:new совпадают.
    const m1 = await send(a.token, conversationId, 'first');
    const m1Event = await bSocket.event<DmMessage>('dm:new');
    expectNoEmail(m1Event);
    expect(m1Event).toEqual(m1);
    expect(m1.conversationId).toBe(conversationId);
    expect(m1.sender.id).toBe(a.id);
    const m2 = await send(b.token, conversationId, 'second');
    expect(await bSocket.event('dm:new')).toEqual(m2);
    const m3 = await send(a.token, conversationId, 'third');
    expect(await bSocket.event('dm:new')).toEqual(m3);
    await cSocket.expectNoEvent('dm:new');
    await anonymous.expectNoEvent('dm:new');

    // История: от старых к новым, курсор before.
    expect((await history(b.token, conversationId)).map((m) => m.id)).toEqual([
      m1.id,
      m2.id,
      m3.id,
    ]);
    const lastPage = await history(b.token, conversationId, '?limit=2');
    expect(lastPage.map((m) => m.id)).toEqual([m2.id, m3.id]);
    lastPage.forEach(expectMessageShape);
    const previousPage = await history(
      b.token,
      conversationId,
      `?limit=2&before=${lastPage[0].id}`,
    );
    expect(previousPage.map((m) => m.id)).toEqual([m1.id]);

    // Курсор after: строго после курсора, от старых к новым.
    const afterFirst = await history(
      b.token,
      conversationId,
      `?after=${m1.id}`,
    );
    expect(afterFirst.map((m) => m.id)).toEqual([m2.id, m3.id]);
    afterFirst.forEach(expectMessageShape);
    expect(await history(b.token, conversationId, `?after=${m3.id}`)).toEqual(
      [],
    );
    await http()
      .get(
        `/dm/conversations/${conversationId}/messages?before=${m3.id}&after=${m1.id}`,
      )
      .set(auth(b.token))
      .expect(400);

    // Чужой: 403 на историю и отправку.
    await http()
      .get(`/dm/conversations/${conversationId}/messages`)
      .set(auth(c.token))
      .expect(403);
    await http()
      .post(`/dm/conversations/${conversationId}/messages`)
      .set(auth(c.token))
      .send({ content: 'intrusion' })
      .expect(403);
    await http()
      .get(`/dm/conversations/${randomUUID()}/messages`)
      .set(auth(a.token))
      .expect(404);

    // Списки A и B содержат диалог с lastMessage той же формы.
    for (const token of [a.token, b.token]) {
      const listed = (await list(token)).find((x) => x.id === conversationId);
      expect(listed).toBeDefined();
      expectConversationShape(listed!);
      expect(listed!.lastMessage).toEqual(m3);
    }
    expect((await list(c.token)).some((x) => x.id === conversationId)).toBe(
      false,
    );

    // Удаление: чужое 403, своё 204 + dm:delete, повтор 404.
    await http().delete(`/dm/messages/${m3.id}`).set(auth(b.token)).expect(403);
    await http().delete(`/dm/messages/${m3.id}`).set(auth(a.token)).expect(204);
    expect(await bSocket.event('dm:delete')).toEqual({
      id: m3.id,
      conversationId,
    });
    await cSocket.expectNoEvent('dm:delete');
    await http().delete(`/dm/messages/${m3.id}`).set(auth(a.token)).expect(404);
    expect((await history(a.token, conversationId)).map((m) => m.id)).toEqual([
      m1.id,
      m2.id,
    ]);
    const afterDelete = (await list(a.token)).find(
      (x) => x.id === conversationId,
    );
    expect(afterDelete!.lastMessage).toEqual(m2);

    // Новое сообщение поднимает диалог вверх списка.
    const other = await http()
      .post('/dm/conversations')
      .set(auth(a.token))
      .send({ userId: c.id })
      .expect(201);
    const otherId = (other.body as DmConversation).id;
    expect((await list(a.token))[0].id).toBe(otherId);
    const bump = await send(b.token, conversationId, 'bump');
    const bumped = await list(a.token);
    expect(bumped.map((x) => x.id)).toEqual([conversationId, otherId]);
    expect(bumped[0].lastMessage).toEqual(bump);
    expect(new Date(bumped[0].updatedAt).getTime()).toBeGreaterThanOrEqual(
      new Date(bump.createdAt).getTime(),
    );
  }, 30000);

  it('discovers a new DM without joining its room and does not notify an outsider', async () => {
    const a = await user('dm-discovery-a');
    const b = await user('dm-discovery-b');
    const c = await user('dm-discovery-c');
    const bSocket = await connect();
    const cSocket = await connect();
    await bSocket.identify(b.token);
    await cSocket.identify(c.token);

    const response = await http()
      .post('/dm/conversations')
      .set(auth(a.token))
      .send({ userId: b.id })
      .expect(201);
    const conversationId = (response.body as DmConversation).id;
    expect(await bSocket.event('dm:conversation:changed')).toEqual({
      conversationId,
    });
    await cSocket.expectNoEvent('dm:conversation:changed');

    await send(a.token, conversationId, 'received without room');
    expect(await bSocket.event('dm:conversation:changed')).toEqual({
      conversationId,
    });
    await bSocket.expectNoEvent('dm:new');
    await cSocket.expectNoEvent('dm:conversation:changed');
  }, 30000);
});
