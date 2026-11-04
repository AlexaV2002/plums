import './ensure-test-database';
import { randomUUID } from 'crypto';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { App } from 'supertest/types';
import { AppModule } from '../src/app.module';
import { PrismaService } from '../src/prisma/prisma.service';
import { MessagesGateway } from '../src/messages/messages.gateway';

describe('message idempotency (e2e)', () => {
  let app: INestApplication<App>;
  let prisma: PrismaService;
  let gateway: MessagesGateway;
  const userIds: string[] = [];

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
    await app.init();
    prisma = app.get(PrismaService);
    gateway = app.get(MessagesGateway);
  });

  afterAll(async () => {
    if (prisma && userIds.length) {
      await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    }
    if (app) await app.close();
  });

  const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

  async function user(label: string) {
    const email = `idem-${label}-${Date.now()}-${Math.random().toString(36).slice(2)}@plums.test`;
    const password = 'SmokeTest-12345';
    const registered = await request(app.getHttpServer())
      .post('/auth/register')
      .send({ username: label, email, password })
      .expect(201);
    const id = (registered.body as { user: { id: string } }).user.id;
    userIds.push(id);
    const loggedIn = await request(app.getHttpServer())
      .post('/auth/login')
      .send({ email, password })
      .expect(201);
    return {
      id,
      token: (loggedIn.body as { accessToken: string }).accessToken,
    };
  }

  async function serverAndChannel(token: string) {
    const server = await request(app.getHttpServer())
      .post('/servers')
      .set(auth(token))
      .send({ name: 'Idempotency e2e' })
      .expect(201);
    const serverId = (server.body as { id: string }).id;
    const channel = await request(app.getHttpServer())
      .post(`/servers/${serverId}/channels`)
      .set(auth(token))
      .send({ name: 'general' })
      .expect(201);
    return { serverId, channelId: (channel.body as { id: string }).id };
  }

  const post = (
    token: string,
    channelId: string,
    content: string,
    clientMessageId?: string,
  ) =>
    request(app.getHttpServer())
      .post(`/channels/${channelId}/messages`)
      .set(auth(token))
      .send({ content, ...(clientMessageId ? { clientMessageId } : {}) });

  it('returns the original message on retry and emits only once', async () => {
    const owner = await user('owner-one');
    const { channelId } = await serverAndChannel(owner.token);
    const clientMessageId = randomUUID();
    const emit = jest.spyOn(gateway, 'emitMessageNew');

    try {
      const first = await post(
        owner.token,
        channelId,
        'hello',
        clientMessageId,
      ).expect(201);
      const retry = await post(
        owner.token,
        channelId,
        'hello',
        clientMessageId,
      ).expect(201);
      expect((retry.body as { id: string }).id).toBe(
        (first.body as { id: string }).id,
      );
      expect(
        await prisma.message.count({ where: { channelId, clientMessageId } }),
      ).toBe(1);
      expect(emit).toHaveBeenCalledTimes(1);

      await post(owner.token, channelId, 'changed', clientMessageId).expect(
        409,
      );
      await request(app.getHttpServer())
        .delete(`/messages/${(first.body as { id: string }).id}`)
        .set(auth(owner.token))
        .expect(200);
      await post(owner.token, channelId, 'hello', clientMessageId).expect(409);
    } finally {
      emit.mockRestore();
    }
  });

  it('accepts only one row from simultaneous requests with the same id', async () => {
    const owner = await user('owner-race');
    const { channelId } = await serverAndChannel(owner.token);
    const clientMessageId = randomUUID();
    const emit = jest.spyOn(gateway, 'emitMessageNew');

    try {
      const replies = await Promise.all(
        Array.from({ length: 8 }, () =>
          post(owner.token, channelId, 'race', clientMessageId),
        ),
      );
      expect(replies.map((reply) => reply.status)).toEqual(Array(8).fill(201));
      expect(
        new Set(replies.map((reply) => (reply.body as { id: string }).id)).size,
      ).toBe(1);
      expect(
        await prisma.message.count({ where: { channelId, clientMessageId } }),
      ).toBe(1);
      expect(emit).toHaveBeenCalledTimes(1);
    } finally {
      emit.mockRestore();
    }
  }, 20_000);

  it('checks membership again before returning an already sent message', async () => {
    const owner = await user('owner-access');
    const member = await user('member-access');
    const { serverId, channelId } = await serverAndChannel(owner.token);
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

    const clientMessageId = randomUUID();
    const ownerMessage = await post(
      owner.token,
      channelId,
      'owner message',
      clientMessageId,
    ).expect(201);
    const memberMessage = await post(
      member.token,
      channelId,
      'member message',
      clientMessageId,
    ).expect(201);
    expect((memberMessage.body as { id: string }).id).not.toBe(
      (ownerMessage.body as { id: string }).id,
    );
    await prisma.serverMember.deleteMany({
      where: { serverId, userId: member.id },
    });
    await post(
      member.token,
      channelId,
      'member message',
      clientMessageId,
    ).expect(403);
  });

  it('keeps legacy posts without an id compatible', async () => {
    const owner = await user('owner-legacy');
    const { channelId } = await serverAndChannel(owner.token);
    const first = await post(owner.token, channelId, 'same content').expect(
      201,
    );
    const second = await post(owner.token, channelId, 'same content').expect(
      201,
    );
    expect((first.body as { id: string }).id).not.toBe(
      (second.body as { id: string }).id,
    );
  });
});
