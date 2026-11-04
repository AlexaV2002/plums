import './ensure-test-database';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomUUID } from 'node:crypto';
import request from 'supertest';
import sharp from 'sharp';
import { AppModule } from '../src/app.module';
import { PrismaService } from '../src/prisma/prisma.service';
import { AttachmentsService } from '../src/attachments/attachments.service';

describe('profile images (e2e)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let png: Buffer;
  const ids: string[] = [];
  const http = () => request(app.getHttpServer());
  const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

  async function account() {
    const email = `${randomUUID()}@plums.test`;
    const password = 'Profile-Images-123';
    const registered = await http()
      .post('/auth/register')
      .send({ username: 'testuser', email, password })
      .expect(201);
    const id = (registered.body as { user: { id: string } }).user.id;
    ids.push(id);
    const login = await http()
      .post('/auth/login')
      .send({ email, password })
      .expect(201);
    return { id, token: (login.body as { accessToken: string }).accessToken };
  }

  beforeAll(async () => {
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
    await app.init();
    prisma = app.get(PrismaService);
    png = await sharp({
      create: { width: 2, height: 2, channels: 3, background: '#124578' },
    })
      .png()
      .toBuffer();
  });

  afterAll(async () => {
    if (prisma && ids.length)
      await prisma.user.deleteMany({ where: { id: { in: ids } } });
    if (app) {
      await app.get(AttachmentsService).cleanup();
      await app.close();
    }
  });

  it('validates, replaces and removes avatars with monotonically increasing versions', async () => {
    const owner = await account();
    const other = await account();
    await http()
      .post('/users/me/avatar')
      .attach('file', png, 'x.png')
      .expect(401);
    await http()
      .post('/users/me/avatar')
      .set(auth(owner.token))
      .attach('file', Buffer.from('<script>'), 'fake.png')
      .expect(400);
    const first = (
      await http()
        .post('/users/me/avatar')
        .set(auth(owner.token))
        .attach('file', png, 'x.png')
        .expect(201)
    ).body as { url: string; revision: number };
    expect(first.revision).toBe(1);
    await http().get(first.url).set(auth(other.token)).expect(200);
    const second = (
      await http()
        .post('/users/me/avatar')
        .set(auth(owner.token))
        .attach('file', png, 'x.png')
        .expect(201)
    ).body as { url: string; revision: number };
    expect(second.revision).toBe(2);
    expect(second.url).not.toBe(first.url);
    await http().get(first.url).set(auth(owner.token)).expect(404);
    const me = await http().get('/users/me').set(auth(owner.token)).expect(200);
    expect(me.body).toMatchObject({
      avatarUrl: second.url,
      profileImageRevision: 2,
    });
    const removed = await http()
      .delete('/users/me/avatar')
      .set(auth(owner.token))
      .expect(200);
    expect(removed.body).toMatchObject({ url: null, revision: 3 });
    await http().get(second.url).set(auth(owner.token)).expect(404);
  }, 30000);

  it('restricts icon writes and reads, and preserves a legacy URL until changed', async () => {
    const owner = await account();
    const outsider = await account();
    const server = await http()
      .post('/servers')
      .set(auth(owner.token))
      .send({
        name: 'profile test',
        iconUrl: 'https://example.test/legacy.png',
      })
      .expect(201);
    const id = (server.body as { id: string }).id;
    const initial = await http()
      .get('/servers')
      .set(auth(owner.token))
      .expect(200);
    expect(initial.body).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id,
          iconUrl: 'https://example.test/legacy.png',
          profileImageRevision: 0,
        }),
      ]),
    );
    await http()
      .post(`/servers/${id}/icon`)
      .set(auth(outsider.token))
      .attach('file', png, 'x.png')
      .expect(403);
    await http()
      .delete(`/servers/${id}/icon`)
      .set(auth(outsider.token))
      .expect(403);
    const image = (
      await http()
        .post(`/servers/${id}/icon`)
        .set(auth(owner.token))
        .attach('file', png, 'x.png')
        .expect(201)
    ).body as { url: string; revision: number };
    await http().get(image.url).set(auth(outsider.token)).expect(403);
    await http().get(image.url).set(auth(owner.token)).expect(200);
    const patched = await http()
      .patch(`/servers/${id}`)
      .set(auth(owner.token))
      .send({ iconUrl: 'https://example.test/new-legacy.png' })
      .expect(200);
    expect(patched.body).toMatchObject({
      iconUrl: 'https://example.test/new-legacy.png',
      profileImageRevision: 2,
    });
    await http().get(image.url).set(auth(owner.token)).expect(404);
  }, 30000);
});
