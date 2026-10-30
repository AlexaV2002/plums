import './ensure-test-database';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { App } from 'supertest/types';
import { AppModule } from '../src/app.module';
import { PrismaService } from '../src/prisma/prisma.service';

// Real concurrency against a real DB: proves Postgres row-locking (not mocks)
// prevents an invite with maxUses from being redeemed more times than allowed.
describe('invite join concurrency (e2e)', () => {
  let app: INestApplication<App>;
  let prisma: PrismaService;
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
  });

  afterAll(async () => {
    if (prisma && userIds.length) {
      await prisma.user.deleteMany({ where: { id: { in: userIds } } });
    }
    if (app) await app.close();
  });

  const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

  async function user(label: string) {
    const email = `invite-${label}-${Date.now()}-${Math.random().toString(36).slice(2)}@plums.test`;
    const password = 'SmokeTest-12345';
    const registered = await request(app.getHttpServer())
      .post('/auth/register')
      .send({ username: label.slice(0, 20), email, password })
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

  async function createServerAndInvite(
    owner: { token: string },
    body: Record<string, unknown> = {},
  ) {
    const server = await request(app.getHttpServer())
      .post('/servers')
      .set(auth(owner.token))
      .send({ name: 'Invite concurrency smoke' })
      .expect(201);
    const serverId = (server.body as { id: string }).id;

    const invite = await request(app.getHttpServer())
      .post(`/servers/${serverId}/invites`)
      .set(auth(owner.token))
      .send(body)
      .expect(201);
    const code = (invite.body as { code: string }).code;

    return { serverId, code };
  }

  function joinAttempt(token: string, code: string) {
    return request(app.getHttpServer())
      .post(`/invites/${code}/join`)
      .set(auth(token))
      .send({});
  }

  it('maxUses=1: exactly 1 of 5 concurrent different users succeeds', async () => {
    const owner = await user(`owner1-${Date.now()}`);
    const { serverId, code } = await createServerAndInvite(owner, { maxUses: 1 });

    const joiners = await Promise.all(
      Array.from({ length: 5 }, (_, i) => user(`joiner1-${i}-${Date.now()}`)),
    );

    const results = await Promise.all(
      joiners.map((joiner) => joinAttempt(joiner.token, code)),
    );

    const succeeded = results.filter((res) => res.status === 201);
    const rejected = results.filter((res) => res.status === 400);

    expect(succeeded).toHaveLength(1);
    expect(rejected).toHaveLength(4);
    rejected.forEach((res) => {
      expect((res.body as { message: string }).message).toMatch(/лимит/i);
    });

    const invite = await prisma.invite.findUnique({ where: { code } });
    expect(invite?.currentUses).toBe(1);

    const memberCount = await prisma.serverMember.count({
      where: { serverId, userId: { not: owner.id } },
    });
    expect(memberCount).toBe(1);
  }, 20000);

  it('maxUses=3: exactly 3 of 7 concurrent different users succeed', async () => {
    const owner = await user(`owner3-${Date.now()}`);
    const { serverId, code } = await createServerAndInvite(owner, { maxUses: 3 });

    const joiners = await Promise.all(
      Array.from({ length: 7 }, (_, i) => user(`joiner3-${i}-${Date.now()}`)),
    );

    const results = await Promise.all(
      joiners.map((joiner) => joinAttempt(joiner.token, code)),
    );

    const succeeded = results.filter((res) => res.status === 201);
    const rejected = results.filter((res) => res.status === 400);

    expect(succeeded).toHaveLength(3);
    expect(rejected).toHaveLength(4);

    const invite = await prisma.invite.findUnique({ where: { code } });
    expect(invite?.currentUses).toBe(3);

    const memberCount = await prisma.serverMember.count({
      where: { serverId, userId: { not: owner.id } },
    });
    expect(memberCount).toBe(3);
  }, 20000);

  it('existing member re-joining succeeds without a second ServerMember or extra currentUses', async () => {
    const owner = await user(`ownerR-${Date.now()}`);
    const member = await user(`memberR-${Date.now()}`);
    const { serverId, code } = await createServerAndInvite(owner, { maxUses: 5 });

    await joinAttempt(member.token, code).expect(201);
    await joinAttempt(member.token, code).expect(201);

    const invite = await prisma.invite.findUnique({ where: { code } });
    expect(invite?.currentUses).toBe(1);

    const memberCount = await prisma.serverMember.count({
      where: { serverId, userId: member.id },
    });
    expect(memberCount).toBe(1);
  }, 20000);

  it('same new user firing 2 parallel joins: both resolve 2xx, 1 ServerMember, currentUses +1', async () => {
    const owner = await user(`ownerP-${Date.now()}`);
    const { serverId, code } = await createServerAndInvite(owner, { maxUses: 5 });
    const joiner = await user(`joinerP-${Date.now()}`);

    const [res1, res2] = await Promise.all([
      joinAttempt(joiner.token, code),
      joinAttempt(joiner.token, code),
    ]);

    expect(res1.status).toBe(201);
    expect(res2.status).toBe(201);

    const invite = await prisma.invite.findUnique({ where: { code } });
    expect(invite?.currentUses).toBe(1);

    const memberCount = await prisma.serverMember.count({
      where: { serverId, userId: joiner.id },
    });
    expect(memberCount).toBe(1);
  }, 20000);

  it('expired invite: 400, and currentUses is not bumped by the rolled-back attempt', async () => {
    const owner = await user(`ownerE-${Date.now()}`);
    // createInvite rejects a past expiresAt at creation time, so a normal
    // invite is created first and then backdated directly via Prisma to
    // simulate one that was "usable" on an earlier read but expires before
    // it's actually redeemed (the race the atomic updateMany in joinInvite's
    // transaction guards against, not just the pre-transaction fast check).
    const { serverId, code } = await createServerAndInvite(owner, {});
    await prisma.invite.update({
      where: { code },
      data: { expiresAt: new Date(Date.now() - 60_000) },
    });
    const joiner = await user(`joinerE-${Date.now()}`);

    const res = await joinAttempt(joiner.token, code).expect(400);
    expect((res.body as { message: string }).message).toMatch(/истёк/i);

    const invite = await prisma.invite.findUnique({ where: { code } });
    expect(invite?.currentUses).toBe(0);

    const memberCount = await prisma.serverMember.count({
      where: { serverId, userId: joiner.id },
    });
    expect(memberCount).toBe(0);
  }, 15000);

  it('banned user: 403 even when limit is not exhausted', async () => {
    const owner = await user(`ownerB-${Date.now()}`);
    const { serverId, code } = await createServerAndInvite(owner, { maxUses: 5 });
    const banned = await user(`joinerB-${Date.now()}`);

    await prisma.serverBan.create({
      data: { serverId, userId: banned.id, bannedBy: owner.id },
    });

    await joinAttempt(banned.token, code).expect(403);
  }, 15000);

  it('non-existent invite code: 404', async () => {
    const owner = await user(`ownerN-${Date.now()}`);
    await joinAttempt(owner.token, 'does-not-exist-code').expect(404);
  }, 15000);

  // Guards the pg_advisory_xact_lock serialization in joinInvite/banServerMember:
  // whichever of the two transactions commits first, the invariant
  // "serverBan exists => serverMember doesn't" must hold afterwards.
  it('concurrent ban + join for the same user never leaves them banned and still a member', async () => {
    const owner = await user(`ownerX-${Date.now()}`);
    const { serverId, code } = await createServerAndInvite(owner, { maxUses: 5 });
    const target = await user(`joinerX-${Date.now()}`);

    const [joinRes, banRes] = await Promise.all([
      joinAttempt(target.token, code),
      request(app.getHttpServer())
        .post(`/servers/${serverId}/bans/${target.id}`)
        .set(auth(owner.token))
        .send({ reason: 'race test' }),
    ]);

    expect([201, 403]).toContain(joinRes.status);
    expect(banRes.status).toBe(201);

    const ban = await prisma.serverBan.findUnique({
      where: { serverId_userId: { serverId, userId: target.id } },
    });
    expect(ban).not.toBeNull();

    const member = await prisma.serverMember.findUnique({
      where: { serverId_userId: { serverId, userId: target.id } },
    });
    expect(member).toBeNull();
  }, 20000);
});
