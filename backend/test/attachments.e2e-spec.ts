import './ensure-test-database';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import * as path from 'node:path';
import { AddressInfo } from 'node:net';
import request from 'supertest';
import sharp from 'sharp';
import { AppModule } from '../src/app.module';
import { PrismaService } from '../src/prisma/prisma.service';
import { AttachmentsService } from '../src/attachments/attachments.service';

type User = { id: string; token: string };
type PublicAttachment = {
  id: string;
  originalName: string;
  mimeType: string;
  sizeBytes: number;
};

class SocketProbe {
  private readonly socket: WebSocket;
  private readonly packets: string[] = [];
  private readonly waiters: Array<{
    match: (packet: string) => boolean;
    done: (packet: string) => void;
  }> = [];
  private nextId = 1;

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

  private wait(
    match: (packet: string) => boolean,
    timeoutMs = 5000,
  ): Promise<string> {
    const index = this.packets.findIndex(match);
    if (index >= 0) return Promise.resolve(this.packets.splice(index, 1)[0]);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const i = this.waiters.indexOf(waiter);
        if (i >= 0) this.waiters.splice(i, 1);
        reject(new Error('Socket packet timeout'));
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

  static async connect(port: number) {
    const probe = new SocketProbe(port);
    await probe.wait((packet) => packet.startsWith('0'));
    probe.socket.send('40');
    await probe.wait((packet) => packet.startsWith('40'));
    return probe;
  }

  async request<T>(event: string, payload: object): Promise<T> {
    const id = this.nextId++;
    this.socket.send(`42${id}${JSON.stringify([event, payload])}`);
    const packet = await this.wait((value) => value.startsWith(`43${id}[`));
    return (JSON.parse(packet.slice(2 + String(id).length)) as T[])[0];
  }

  async event<T>(name: string): Promise<T> {
    const packet = await this.wait(
      (value) =>
        value.startsWith('42') &&
        (JSON.parse(value.slice(2)) as [string])[0] === name,
    );
    return (JSON.parse(packet.slice(2)) as [string, T])[1];
  }

  close() {
    this.socket.close();
  }
}

describe('channel image attachments (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let cleanup: AttachmentsService;
  let root: string;
  let previousStorageDir: string | undefined;
  let png: Buffer;
  let owner: User;
  let member: User;
  let outsider: User;
  let serverId: string;
  let channelId: string;
  let port: number;
  const sockets: SocketProbe[] = [];
  const users: string[] = [];
  const auth = (user: User) => ({ Authorization: `Bearer ${user.token}` });
  const http = () => request(app.getHttpServer());

  async function user(label: string): Promise<User> {
    const email = `${label}-${randomUUID()}@plums.test`;
    const password = 'Attachments-Test-123';
    const registered = await http()
      .post('/auth/register')
      .send({ username: label, email, password })
      .expect(201);
    const id = (registered.body as { user: { id: string } }).user.id;
    users.push(id);
    const login = await http()
      .post('/auth/login')
      .send({ email, password })
      .expect(201);
    return { id, token: (login.body as { accessToken: string }).accessToken };
  }

  async function upload(user: User, data: Buffer, name = 'image.png') {
    const response = await http()
      .post(`/channels/${channelId}/attachments`)
      .set(auth(user))
      .attach('file', data, {
        filename: name,
        contentType: 'application/octet-stream',
      });
    return response;
  }

  beforeAll(async () => {
    previousStorageDir = process.env.ATTACHMENT_STORAGE_DIR;
    const base = path.resolve(process.cwd(), '.tmp');
    root = path.join(base, `attachments-e2e-${randomUUID()}`);
    if (!root.startsWith(base + path.sep))
      throw new Error('Invalid test storage path');
    process.env.ATTACHMENT_STORAGE_DIR = root;
    const module = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();
    app = module.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
    );
    await app.listen(0, '127.0.0.1');
    port = (app.getHttpServer().address() as AddressInfo).port;
    expect(port).toBeGreaterThan(0);
    prisma = app.get(PrismaService);
    cleanup = app.get(AttachmentsService);
    png = await sharp({
      create: { width: 3, height: 3, channels: 3, background: '#815cff' },
    })
      .png()
      .toBuffer();
    owner = await user('attachment-owner');
    member = await user('attachment-member');
    outsider = await user('attachment-outsider');
    const server = await http()
      .post('/servers')
      .set(auth(owner))
      .send({ name: 'Attachments' })
      .expect(201);
    serverId = (server.body as { id: string }).id;
    const channel = await http()
      .post(`/servers/${serverId}/channels`)
      .set(auth(owner))
      .send({ name: 'images' })
      .expect(201);
    channelId = (channel.body as { id: string }).id;
    const invite = await http()
      .post(`/servers/${serverId}/invites`)
      .set(auth(owner))
      .send({})
      .expect(201);
    await http()
      .post(`/invites/${(invite.body as { code: string }).code}/join`)
      .set(auth(member))
      .send({})
      .expect(201);
  }, 30000);

  afterAll(async () => {
    sockets.forEach((socket) => socket.close());
    if (sockets.length)
      await new Promise((resolve) => setTimeout(resolve, 250));
    if (prisma && users.length)
      await prisma.user.deleteMany({ where: { id: { in: users } } });
    if (cleanup) await cleanup.cleanup();
    if (app) await app.close();
    if (root) await fs.rm(root, { recursive: true, force: true });
    if (previousStorageDir === undefined)
      delete process.env.ATTACHMENT_STORAGE_DIR;
    else process.env.ATTACHMENT_STORAGE_DIR = previousStorageDir;
  });

  it('validates bytes, size, access and attaches atomically with idempotent history', async () => {
    await http()
      .post(`/channels/${channelId}/attachments`)
      .attach('file', png, 'a.png')
      .expect(401);
    expect((await upload(outsider, png)).status).toBe(403);
    expect(
      (await upload(member, Buffer.from('not an image'), 'fake.png')).status,
    ).toBe(400);
    expect(
      (await upload(member, png.subarray(0, 20), 'truncated.png')).status,
    ).toBe(400);
    expect(
      (await upload(member, Buffer.alloc(10 * 1024 * 1024 + 1), 'large.png'))
        .status,
    ).toBe(413);
    await http()
      .post(`/channels/${channelId}/messages`)
      .set(auth(member))
      .send({
        content: 'too many',
        attachmentIds: Array.from({ length: 5 }, () => randomUUID()),
      })
      .expect(400);
    const uploaded = await upload(member, png, '../image.txt');
    expect(uploaded.status).toBe(201);
    const item = uploaded.body as PublicAttachment;
    expect(item.mimeType).toBe('image/png');
    expect(item.originalName).toBe('image.txt');
    expect(item).not.toHaveProperty('storageKey');
    await http()
      .get(`/attachments/${item.id}/content`)
      .set(auth(member))
      .expect(404);
    await http()
      .post(`/channels/${channelId}/messages`)
      .set(auth(owner))
      .send({ content: '', attachmentIds: [item.id] })
      .expect(400);

    const clientMessageId = randomUUID();
    const payload = { content: '', clientMessageId, attachmentIds: [item.id] };
    const created = await http()
      .post(`/channels/${channelId}/messages`)
      .set(auth(member))
      .send(payload)
      .expect(201);
    const message = created.body as {
      id: string;
      attachments: PublicAttachment[];
    };
    expect(message.attachments).toHaveLength(1);
    expect(message.attachments[0]).toEqual(item);
    await http()
      .delete(`/attachments/${item.id}`)
      .set(auth(member))
      .expect(404);
    const retry = await http()
      .post(`/channels/${channelId}/messages`)
      .set(auth(member))
      .send(payload)
      .expect(201);
    expect((retry.body as { id: string }).id).toBe(message.id);
    await http()
      .post(`/channels/${channelId}/messages`)
      .set(auth(member))
      .send({ ...payload, attachmentIds: [] })
      .expect(409);
    const history = await http()
      .get(`/channels/${channelId}/messages`)
      .set(auth(owner))
      .expect(200);
    expect(
      (
        history.body as Array<{ id: string; attachments: PublicAttachment[] }>
      ).find((m) => m.id === message.id)?.attachments,
    ).toEqual([item]);
    await http()
      .get(`/attachments/${item.id}/content`)
      .set(auth(outsider))
      .expect(403);
    const image = await http()
      .get(`/attachments/${item.id}/content`)
      .set(auth(owner))
      .expect(200);
    expect(image.headers['content-type']).toMatch(/^image\/png/);
    expect(image.headers['x-content-type-options']).toBe('nosniff');
    await http()
      .patch(`/channels/${channelId}/permissions`)
      .set(auth(owner))
      .send({ canView: false })
      .expect(200);
    await http()
      .get(`/attachments/${item.id}/content`)
      .set(auth(member))
      .expect(403);
    await http()
      .patch(`/channels/${channelId}/permissions`)
      .set(auth(owner))
      .send({ canView: true })
      .expect(200);
    await http()
      .delete(`/messages/${message.id}`)
      .set(auth(member))
      .expect(200);
    await http()
      .get(`/attachments/${item.id}/content`)
      .set(auth(owner))
      .expect(404);
    expect(await prisma.attachmentCleanup.count()).toBeGreaterThan(0);
    await cleanup.cleanup();
    expect(await prisma.attachmentCleanup.count()).toBe(0);
  }, 30000);

  it('allows only one concurrent message to claim the same image', async () => {
    const uploaded = await upload(member, png);
    expect(uploaded.status).toBe(201);
    const id = (uploaded.body as PublicAttachment).id;
    const post = () =>
      http()
        .post(`/channels/${channelId}/messages`)
        .set(auth(member))
        .send({
          content: 'race',
          clientMessageId: randomUUID(),
          attachmentIds: [id],
        });
    const responses = await Promise.all([post(), post()]);
    expect(responses.map((response) => response.status).sort()).toEqual([
      201, 400,
    ]);
    expect(
      await prisma.attachment.count({ where: { id, state: 'ATTACHED' } }),
    ).toBe(1);
  }, 30000);

  it('returns one message for concurrent retries with the same client message id and image', async () => {
    const uploaded = await upload(member, png);
    const attachmentId = (uploaded.body as PublicAttachment).id;
    const clientMessageId = randomUUID();
    const payload = {
      content: 'retry',
      clientMessageId,
      attachmentIds: [attachmentId],
    };
    const post = () =>
      http()
        .post(`/channels/${channelId}/messages`)
        .set(auth(member))
        .send(payload);
    const responses = await Promise.all([post(), post()]);
    expect(responses.map((response) => response.status)).toEqual([201, 201]);
    expect((responses[0].body as { id: string }).id).toBe(
      (responses[1].body as { id: string }).id,
    );
    expect(
      await prisma.message.count({
        where: { channelId, authorId: member.id, clientMessageId },
      }),
    ).toBe(1);
  }, 30000);

  it('accepts JPEG/WebP and delivers safe image metadata through realtime', async () => {
    const socket = await SocketProbe.connect(port);
    sockets.push(socket);
    expect(
      (
        await socket.request<{ userId: string }>('presence:identify', {
          token: member.token,
        })
      ).userId,
    ).toBe(member.id);
    expect(await socket.request('channel:join', { channelId })).toMatchObject({
      joined: true,
      channelId,
    });
    const jpg = await sharp({
      create: { width: 2, height: 2, channels: 3, background: '#112233' },
    })
      .jpeg()
      .toBuffer();
    const webp = await sharp({
      create: { width: 2, height: 2, channels: 3, background: '#445566' },
    })
      .webp()
      .toBuffer();
    const imageA = (await upload(owner, jpg, 'a.jpg')).body as PublicAttachment;
    const imageB = (await upload(owner, webp, 'b.webp'))
      .body as PublicAttachment;
    expect(imageA.mimeType).toBe('image/jpeg');
    expect(imageB.mimeType).toBe('image/webp');
    const response = await http()
      .post(`/channels/${channelId}/messages`)
      .set(auth(owner))
      .send({ content: 'images', attachmentIds: [imageA.id, imageB.id] })
      .expect(201);
    const live = await socket.event<{
      id: string;
      attachments: PublicAttachment[];
    }>('message:new');
    expect(live.id).toBe((response.body as { id: string }).id);
    expect(live.attachments.map((item) => item.id).sort()).toEqual(
      [imageA.id, imageB.id].sort(),
    );
    expect(live.attachments.every((item) => !('storageKey' in item))).toBe(
      true,
    );
    await http()
      .get(`/attachments/${imageA.id}/content`)
      .set(auth(member))
      .expect(200);
  }, 30000);

  it('cleans expired unattached uploads and their stored bytes', async () => {
    const uploaded = await upload(member, png);
    expect(uploaded.status).toBe(201);
    const item = uploaded.body as PublicAttachment;
    const record = await prisma.attachment.findUniqueOrThrow({
      where: { id: item.id },
    });
    const storedFile = path.join(root, record.storageKey);
    await expect(fs.stat(storedFile)).resolves.toBeDefined();
    await prisma.attachment.update({
      where: { id: item.id },
      data: { expiresAt: new Date(Date.now() - 1000) },
    });
    await cleanup.cleanup();
    expect(
      await prisma.attachment.findUnique({ where: { id: item.id } }),
    ).toBeNull();
    await expect(fs.stat(storedFile)).rejects.toMatchObject({ code: 'ENOENT' });
  }, 30000);

  it('allows only the uploader to discard an unattached image', async () => {
    const uploaded = await upload(member, png);
    const item = uploaded.body as PublicAttachment;
    expect(uploaded.status).toBe(201);
    await http().delete(`/attachments/${item.id}`).set(auth(owner)).expect(404);
    expect(
      await prisma.attachment.findUnique({ where: { id: item.id } }),
    ).not.toBeNull();
    await http()
      .delete(`/attachments/${item.id}`)
      .set(auth(member))
      .expect(204);
    expect(
      await prisma.attachment.findUnique({ where: { id: item.id } }),
    ).toBeNull();
    await http()
      .delete(`/attachments/${item.id}`)
      .set(auth(member))
      .expect(404);
  }, 30000);

  it('preserves a Cyrillic image filename', async () => {
    const uploaded = await upload(member, png, 'картинка.png');
    expect(uploaded.status).toBe(201);
    expect((uploaded.body as PublicAttachment).originalName).toBe('картинка.png');
  }, 30000);

  it('retains the image and access checks after backend restart', async () => {
    const uploaded = await upload(owner, png, 'restart.png');
    expect(uploaded.status).toBe(201);
    const item = uploaded.body as PublicAttachment;
    await http()
      .post(`/channels/${channelId}/messages`)
      .set(auth(owner))
      .send({ content: '', attachmentIds: [item.id] })
      .expect(201);
    const before = await http()
      .get(`/attachments/${item.id}/content`)
      .set(auth(member))
      .expect(200);

    sockets.forEach((socket) => socket.close());
    sockets.length = 0;
    await new Promise((resolve) => setTimeout(resolve, 250));
    await app.close();
    const module = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();
    app = module.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
    );
    await app.listen(0, '127.0.0.1');
    prisma = app.get(PrismaService);
    cleanup = app.get(AttachmentsService);

    const after = await http()
      .get(`/attachments/${item.id}/content`)
      .set(auth(member))
      .expect(200);
    expect(after.body).toEqual(before.body);
    await http()
      .get(`/attachments/${item.id}/content`)
      .set(auth(outsider))
      .expect(403);
  }, 30000);
});
