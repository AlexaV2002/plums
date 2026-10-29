import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Prisma } from '@prisma/client';
import { createHash, randomUUID } from 'crypto';
import request from 'supertest';
import { App } from 'supertest/types';
import { AppModule } from '../src/app.module';
import { PrismaService } from '../src/prisma/prisma.service';

type AuthResponse = {
  accessToken: string;
  refreshToken: string;
  user: { id: string; email: string };
};

describe('refresh token rotation (isolated PostgreSQL e2e)', () => {
  let app: INestApplication<App>;
  let prisma: PrismaService;
  let previousDatabaseUrl: string | undefined;
  let previousJwtSecret: string | undefined;
  let changedEnvironment = false;
  const userIds: string[] = [];

  beforeAll(async () => {
    const testDatabaseUrl = process.env.AUTH_TEST_DATABASE_URL;
    if (!testDatabaseUrl) {
      throw new Error(
        'AUTH_TEST_DATABASE_URL is required for isolated auth tests',
      );
    }
    const parsed = new URL(testDatabaseUrl);
    const database = decodeURIComponent(parsed.pathname.slice(1));
    if (
      !['localhost', '127.0.0.1'].includes(parsed.hostname) ||
      parsed.port === '5432' ||
      !/^plums_auth_test_[a-z0-9_]+$/i.test(database) ||
      testDatabaseUrl === process.env.DATABASE_URL
    ) {
      throw new Error(
        'Auth tests require a separate local PostgreSQL test database',
      );
    }

    previousDatabaseUrl = process.env.DATABASE_URL;
    previousJwtSecret = process.env.JWT_SECRET;
    changedEnvironment = true;
    process.env.DATABASE_URL = testDatabaseUrl;
    process.env.JWT_SECRET = 'plums-auth-refresh-e2e-secret';
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
  }, 60000);

  afterAll(async () => {
    if (prisma && userIds.length) {
      await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    }
    if (app) await app.close();
    if (changedEnvironment) {
      if (previousDatabaseUrl === undefined) delete process.env.DATABASE_URL;
      else process.env.DATABASE_URL = previousDatabaseUrl;
      if (previousJwtSecret === undefined) delete process.env.JWT_SECRET;
      else process.env.JWT_SECRET = previousJwtSecret;
    }
  });

  async function login(): Promise<AuthResponse> {
    const email = `auth-refresh-${randomUUID()}@plums.test`;
    const password = 'AuthRefresh-12345';
    const registered = await request(app.getHttpServer())
      .post('/auth/register')
      .send({ username: 'Refresh tester', email, password })
      .expect(201);
    userIds.push((registered.body as { user: { id: string } }).user.id);

    const response = await request(app.getHttpServer())
      .post('/auth/login')
      .send({ email, password })
      .expect(201);
    return response.body as AuthResponse;
  }

  it('rotates a valid token and keeps the REST session usable', async () => {
    const initial = await login();
    const response = await request(app.getHttpServer())
      .post('/auth/refresh')
      .send({ refreshToken: initial.refreshToken })
      .expect(201);
    const rotated = response.body as AuthResponse;

    expect(rotated.user.id).toBe(initial.user.id);
    expect(rotated.refreshToken).not.toBe(initial.refreshToken);
    const oldHash = createHash('sha256')
      .update(initial.refreshToken)
      .digest('hex');
    const oldToken = await prisma.refreshToken.findUnique({
      where: { tokenHash: oldHash },
    });
    expect(oldToken?.revokedAt).not.toBeNull();
    await request(app.getHttpServer())
      .get('/users/me')
      .set('Authorization', `Bearer ${rotated.accessToken}`)
      .expect(200);
  });

  it('returns 401 when a rotated token is reused', async () => {
    const initial = await login();
    const first = await request(app.getHttpServer())
      .post('/auth/refresh')
      .send({ refreshToken: initial.refreshToken })
      .expect(201);
    await request(app.getHttpServer())
      .post('/auth/refresh')
      .send({ refreshToken: initial.refreshToken })
      .expect(401);
    await request(app.getHttpServer())
      .post('/auth/refresh')
      .send({ refreshToken: (first.body as AuthResponse).refreshToken })
      .expect(201);
  });

  it('returns 401 for an expired token without creating a successor', async () => {
    const initial = await login();
    const tokenHash = createHash('sha256')
      .update(initial.refreshToken)
      .digest('hex');
    await prisma.refreshToken.update({
      where: { tokenHash },
      data: { expiresAt: new Date(Date.now() - 1000) },
    });
    await request(app.getHttpServer())
      .post('/auth/refresh')
      .send({ refreshToken: initial.refreshToken })
      .expect(401);
    expect(
      await prisma.refreshToken.count({ where: { userId: initial.user.id } }),
    ).toBe(1);
  });

  it('allows exactly one of two concurrent refresh requests', async () => {
    const initial = await login();
    // Both requests must read the same valid row before either can revoke it.
    // This barrier makes the old read-then-update race reproducible.
    const delegate = prisma.refreshToken;
    const originalFindUnique = delegate.findUnique.bind(delegate) as (
      args: Prisma.RefreshTokenFindUniqueArgs,
    ) => Promise<unknown>;
    let reads = 0;
    let releaseReads: () => void = () => undefined;
    const bothRead = new Promise<void>((resolve) => {
      releaseReads = resolve;
    });
    const gateTimeout = setTimeout(releaseReads, 3000);
    const findSpy = jest
      .spyOn(delegate, 'findUnique')
      .mockImplementation(async (args) => {
        const result = await originalFindUnique(args);
        if (++reads === 2) {
          clearTimeout(gateTimeout);
          releaseReads();
        }
        await bothRead;
        return result as Awaited<ReturnType<typeof delegate.findUnique>>;
      });

    let statuses: number[] = [];
    try {
      statuses = (
        await Promise.all([
          request(app.getHttpServer())
            .post('/auth/refresh')
            .send({ refreshToken: initial.refreshToken }),
          request(app.getHttpServer())
            .post('/auth/refresh')
            .send({ refreshToken: initial.refreshToken }),
        ])
      ).map((response: { status: number }) => response.status);
    } finally {
      clearTimeout(gateTimeout);
      findSpy.mockRestore();
    }
    expect(reads).toBe(2);
    expect(statuses.sort()).toEqual([201, 401]);
    expect(
      await prisma.refreshToken.count({
        where: { userId: initial.user.id, revokedAt: null },
      }),
    ).toBe(1);
  });

  it('keeps logout idempotent and rejects the logged-out token', async () => {
    const initial = await login();
    await request(app.getHttpServer())
      .post('/auth/logout')
      .send({ refreshToken: initial.refreshToken })
      .expect(201);
    await request(app.getHttpServer())
      .post('/auth/logout')
      .send({ refreshToken: initial.refreshToken })
      .expect(201);
    await request(app.getHttpServer())
      .post('/auth/refresh')
      .send({ refreshToken: initial.refreshToken })
      .expect(401);
  });
});
