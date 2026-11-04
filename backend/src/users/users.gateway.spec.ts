import { Test, TestingModule } from '@nestjs/testing';
import { JwtService } from '@nestjs/jwt';
import { PrismaService } from '../prisma/prisma.service';
import { ServersGateway } from '../servers/servers.gateway';
import { getActiveSocketIdentity, UsersGateway } from './users.gateway';

type MockSocket = {
  data: Record<string, unknown>;
  rooms: Set<string>;
  join: jest.Mock;
  leave: jest.Mock;
  emit: jest.Mock;
  disconnect: jest.Mock;
};

describe('UsersGateway', () => {
  let gateway: UsersGateway;
  let jwtService: { verifyAsync: jest.Mock };
  let prisma: {
    user: { update: jest.Mock };
    serverMember: { findFirst: jest.Mock };
  };
  let sockets: Map<string, MockSocket>;

  function createSocket(): MockSocket {
    const socket: MockSocket = {
      data: {},
      rooms: new Set(['socket-1']),
      join: jest.fn(),
      leave: jest.fn(),
      emit: jest.fn(),
      disconnect: jest.fn(),
    };

    // Как в socket.io: leave убирает комнату из набора rooms.
    socket.leave.mockImplementation((room: string) => {
      socket.rooms.delete(room);
    });

    return socket;
  }

  beforeEach(async () => {
    jwtService = { verifyAsync: jest.fn() };
    prisma = {
      user: { update: jest.fn().mockResolvedValue({}) },
      serverMember: { findFirst: jest.fn().mockResolvedValue(null) },
    };
    sockets = new Map();

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        UsersGateway,
        { provide: JwtService, useValue: jwtService },
        { provide: PrismaService, useValue: prisma },
      ],
    }).compile();

    gateway = module.get<UsersGateway>(UsersGateway);
    gateway.server = { sockets: { sockets }, emit: jest.fn() } as never;
  });

  describe('user:status privacy', () => {
    function identifiedSocket(userId: string) {
      const socket = createSocket();
      socket.data = {
        userId,
        authExpiresAt: Date.now() + 60_000,
        identityVersion: 1,
      };
      return socket;
    }

    it('sends only to the user and members of a common server', async () => {
      const owner = identifiedSocket('subject');
      const sharedFirst = identifiedSocket('shared');
      const sharedSecond = identifiedSocket('shared');
      const stranger = identifiedSocket('stranger');
      const anonymous = createSocket();
      [owner, sharedFirst, sharedSecond, stranger, anonymous].forEach(
        (socket, index) => sockets.set(String(index), socket),
      );
      prisma.serverMember.findFirst.mockImplementation(
        ({ where }: { where: { userId: string } }) =>
          where.userId === 'shared' ? { id: 'membership' } : null,
      );

      await gateway.emitUserStatus('subject', 'ONLINE');

      for (const socket of [owner, sharedFirst, sharedSecond]) {
        expect(socket.emit).toHaveBeenCalledWith('user:status', {
          userId: 'subject',
          status: 'ONLINE',
        });
      }
      expect(stranger.emit).not.toHaveBeenCalled();
      expect(anonymous.emit).not.toHaveBeenCalled();
    });

    it('stops delivery after membership loss or account switch during lookup', async () => {
      const socket = identifiedSocket('shared');
      sockets.set('one', socket);
      prisma.serverMember.findFirst
        .mockResolvedValueOnce({ id: 'membership' })
        .mockResolvedValueOnce(null);

      await gateway.emitUserStatus('subject', 'ONLINE');
      socket.emit.mockClear();
      await gateway.emitUserStatus('subject', 'OFFLINE');
      expect(socket.emit).not.toHaveBeenCalled();

      let releaseLookup!: (value: { id: string }) => void;
      prisma.serverMember.findFirst.mockImplementationOnce(
        () =>
          new Promise<{ id: string }>((resolve) => {
            releaseLookup = resolve;
          }),
      );
      const pending = gateway.emitUserStatus('subject', 'ONLINE');
      await new Promise((resolve) => setImmediate(resolve));
      socket.data.userId = 'stranger';
      socket.data.identityVersion = 2;
      releaseLookup({ id: 'membership' });
      await pending;
      expect(socket.emit).not.toHaveBeenCalled();
    });
  });

  describe('presence:identify', () => {
    it('should set client.data.userId and acknowledge identify', async () => {
      jwtService.verifyAsync.mockResolvedValue({
        sub: 'user-1',
        email: 'user-1@plums.test',
        exp: Date.now() / 1000 + 60,
      });

      const client = createSocket();
      const ack = jest.fn();

      await gateway.identify({ token: 'valid-token' }, client as never, ack);

      expect(client.data.userId).toBe('user-1');
      expect(ack).toHaveBeenCalledTimes(1);
      expect(ack).toHaveBeenCalledWith({ userId: 'user-1' });
    });

    it('should acknowledge repeated identify for the same user (reconnect)', async () => {
      jwtService.verifyAsync.mockResolvedValue({
        sub: 'user-1',
        email: 'user-1@plums.test',
        exp: Date.now() / 1000 + 60,
      });

      const client = createSocket();
      const firstAck = jest.fn();
      await gateway.identify(
        { token: 'valid-token' },
        client as never,
        firstAck,
      );

      const secondAck = jest.fn();
      await gateway.identify(
        { token: 'valid-token' },
        client as never,
        secondAck,
      );

      // Early-return ветка: клиент всё равно должен получить подтверждение,
      // иначе reconnect того же пользователя никогда не дожмётся.
      expect(secondAck).toHaveBeenCalledTimes(1);
      expect(secondAck).toHaveBeenCalledWith({ userId: 'user-1' });

      // Счётчик подключений не дублируется, статус не переписывается.
      expect(prisma.user.update).toHaveBeenCalledTimes(1);
    });

    it('keeps a user online while another device is still connected', async () => {
      jwtService.verifyAsync.mockResolvedValue({
        sub: 'user-1',
        email: 'user-1@plums.test',
        exp: Date.now() / 1000 + 60,
      });
      const first = createSocket();
      const second = createSocket();
      await gateway.identify({ token: 'valid' }, first as never, jest.fn());
      await gateway.identify({ token: 'valid' }, second as never, jest.fn());
      await gateway.handleDisconnect(first as never);
      expect(prisma.user.update).toHaveBeenCalledTimes(1);
      await gateway.handleDisconnect(second as never);
      expect(prisma.user.update).toHaveBeenLastCalledWith(
        expect.objectContaining({ data: { status: 'OFFLINE' } }),
      );
    });

    it('serializes OFFLINE then ONLINE when reconnect races with disconnect', async () => {
      jwtService.verifyAsync.mockResolvedValue({
        sub: 'user-1',
        email: 'user-1@plums.test',
        exp: Date.now() / 1000 + 60,
      });
      const first = createSocket();
      await gateway.identify({ token: 'valid' }, first as never, jest.fn());

      let releaseOffline!: () => void;
      const offlineGate = new Promise<void>((resolve) => {
        releaseOffline = resolve;
      });
      prisma.user.update.mockImplementation(
        ({ data }: { data: { status: string } }) =>
          data.status === 'OFFLINE' ? offlineGate : Promise.resolve({}),
      );
      const disconnect = gateway.handleDisconnect(first as never);
      await new Promise((resolve) => setImmediate(resolve));
      const second = createSocket();
      const secondAck = jest.fn();
      const reconnect = gateway.identify(
        { token: 'valid' },
        second as never,
        secondAck,
      );
      await new Promise((resolve) => setImmediate(resolve));
      releaseOffline();
      await Promise.all([disconnect, reconnect]);

      expect(secondAck).toHaveBeenCalledWith({ userId: 'user-1' });
      expect(
        prisma.user.update.mock.calls.map(([args]) => args.data.status),
      ).toEqual(['ONLINE', 'OFFLINE', 'ONLINE']);
    });

    it('should signal an invalid token and not acknowledge', async () => {
      jwtService.verifyAsync.mockRejectedValue(new Error('invalid token'));

      const client = createSocket();
      const ack = jest.fn();

      await gateway.identify({ token: 'bad-token' }, client as never, ack);

      expect(client.emit).toHaveBeenCalledWith('session:expired', {
        reason: 'invalid_token',
      });
      expect(client.disconnect).not.toHaveBeenCalled();
      expect(client.data.userId).toBeUndefined();
      expect(ack).not.toHaveBeenCalled();
    });

    it('should leave old dm:* rooms when the account changes on the same socket', async () => {
      jwtService.verifyAsync
        .mockResolvedValueOnce({
          sub: 'user-1',
          email: 'user-1@plums.test',
          exp: Date.now() / 1000 + 60,
        })
        .mockResolvedValueOnce({
          sub: 'user-2',
          email: 'user-2@plums.test',
          exp: Date.now() / 1000 + 60,
        });

      const client = createSocket();
      await gateway.identify({ token: 'token-1' }, client as never, jest.fn());
      expect(client.data.userId).toBe('user-1');

      // user-1 уже успел присоединиться к своим dm-комнатам.
      client.rooms.add('dm:conversation-1');
      client.rooms.add('dm:conversation-2');
      client.rooms.add('server:server-1');
      client.rooms.add('channel:channel-1');
      // Комнаты без защищённого префикса не трогаем.
      client.rooms.add('custom-room');

      const ack = jest.fn();
      await gateway.identify({ token: 'token-2' }, client as never, ack);

      // Страницы прежнего аккаунта покинуты, новый аккаунт подтверждён.
      expect(client.leave).toHaveBeenCalledWith('dm:conversation-1');
      expect(client.leave).toHaveBeenCalledWith('dm:conversation-2');
      expect(client.leave).toHaveBeenCalledWith('server:server-1');
      expect(client.leave).toHaveBeenCalledWith('channel:channel-1');
      expect(client.leave).not.toHaveBeenCalledWith('custom-room');
      expect(prisma.user.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: 'user-1' },
          data: { status: 'OFFLINE' },
        }),
      );
      expect(client.data.userId).toBe('user-2');
      expect(ack).toHaveBeenCalledWith({ userId: 'user-2' });
    });

    it('clears stale protected rooms before the first identity', async () => {
      jwtService.verifyAsync.mockResolvedValue({
        sub: 'user-1',
        email: 'user-1@plums.test',
        exp: Date.now() / 1000 + 60,
      });

      const client = createSocket();
      client.rooms.add('dm:conversation-1');

      await gateway.identify(
        { token: 'valid-token' },
        client as never,
        jest.fn(),
      );

      expect(client.leave).toHaveBeenCalledWith('dm:conversation-1');
      expect(client.data.userId).toBe('user-1');
    });

    it('rejects an expired JWT and one without exp', async () => {
      const client = createSocket();
      const ack = jest.fn();
      const expired = new Error('jwt expired');
      expired.name = 'TokenExpiredError';
      jwtService.verifyAsync
        .mockRejectedValueOnce(expired)
        .mockResolvedValueOnce({ sub: 'user-1', email: 'user-1@plums.test' });

      await gateway.identify({ token: 'expired' }, client as never, ack);
      expect(client.emit).toHaveBeenCalledWith('session:expired', {
        reason: 'token_expired',
      });
      await gateway.identify({ token: 'no-exp' }, client as never, ack);
      expect(client.emit).toHaveBeenCalledWith('session:expired', {
        reason: 'invalid_token',
      });
      expect(ack).not.toHaveBeenCalled();
      expect(client.data.userId).toBeUndefined();
    });

    it('extends the same user session with a newly verified JWT', async () => {
      jest.useFakeTimers();
      try {
        jwtService.verifyAsync
          .mockResolvedValueOnce({
            sub: 'user-1',
            email: 'user-1@plums.test',
            exp: Date.now() / 1000 + 1,
          })
          .mockResolvedValueOnce({
            sub: 'user-1',
            email: 'user-1@plums.test',
            exp: Date.now() / 1000 + 60,
          });
        const client = createSocket();
        await gateway.identify({ token: 'short' }, client as never, jest.fn());
        client.rooms.add('channel:one');
        const ack = jest.fn();
        await gateway.identify({ token: 'fresh' }, client as never, ack);

        await jest.advanceTimersByTimeAsync(1100);
        expect(jwtService.verifyAsync).toHaveBeenCalledTimes(2);
        expect(client.data.userId).toBe('user-1');
        expect(client.rooms.has('channel:one')).toBe(true);
        expect(client.emit).not.toHaveBeenCalledWith(
          'session:expired',
          expect.anything(),
        );
        expect(prisma.user.update).toHaveBeenCalledTimes(1);
        expect(ack).toHaveBeenCalledWith({ userId: 'user-1' });
      } finally {
        jest.useRealTimers();
      }
    });

    it('expires only the affected socket when two clients share an account', async () => {
      jest.useFakeTimers();
      try {
        jwtService.verifyAsync.mockImplementation((token: string) => ({
          sub: 'user-1',
          email: 'user-1@plums.test',
          exp: Date.now() / 1000 + (token === 'short' ? 1 : 60),
        }));
        const expiredClient = createSocket();
        const activeClient = createSocket();
        await gateway.identify(
          { token: 'short' },
          expiredClient as never,
          jest.fn(),
        );
        await gateway.identify(
          { token: 'long' },
          activeClient as never,
          jest.fn(),
        );
        for (const room of ['server:one', 'channel:one', 'dm:one']) {
          expiredClient.rooms.add(room);
          activeClient.rooms.add(room);
        }

        await jest.advanceTimersByTimeAsync(1100);
        expect(expiredClient.data.userId).toBeUndefined();
        expect(expiredClient.rooms).toEqual(new Set(['socket-1']));
        expect(expiredClient.emit).toHaveBeenCalledWith('session:expired', {
          reason: 'token_expired',
        });
        expect(activeClient.data.userId).toBe('user-1');
        expect(activeClient.rooms.has('channel:one')).toBe(true);
        expect(prisma.user.update).toHaveBeenCalledTimes(1);
      } finally {
        jest.useRealTimers();
      }
    });

    it('serializes concurrent identify calls on the same socket', async () => {
      let releaseFirst!: () => void;
      const firstVerification = new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });
      jwtService.verifyAsync.mockImplementation(async (token: string) => {
        if (token === 'first') await firstVerification;
        return {
          sub: token === 'first' ? 'user-1' : 'user-2',
          email: `${token}@plums.test`,
          exp: Date.now() / 1000 + 60,
        };
      });
      const client = createSocket();
      const firstAck = jest.fn();
      const secondAck = jest.fn();
      const first = gateway.identify(
        { token: 'first' },
        client as never,
        firstAck,
      );
      const second = gateway.identify(
        { token: 'second' },
        client as never,
        secondAck,
      );
      await new Promise((resolve) => setImmediate(resolve));
      expect(jwtService.verifyAsync).toHaveBeenCalledTimes(1);
      releaseFirst();
      await Promise.all([first, second]);

      expect(firstAck).toHaveBeenCalledWith({ userId: 'user-1' });
      expect(secondAck).toHaveBeenCalledWith({ userId: 'user-2' });
      expect(client.data.userId).toBe('user-2');
      expect(prisma.user.update).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { id: 'user-1' },
          data: { status: 'OFFLINE' },
        }),
      );
    });

    it('blocks protected joins before awaiting room cleanup on account switch', async () => {
      jwtService.verifyAsync
        .mockResolvedValueOnce({
          sub: 'user-1',
          email: 'user-1@plums.test',
          exp: Date.now() / 1000 + 60,
        })
        .mockResolvedValueOnce({
          sub: 'user-2',
          email: 'user-2@plums.test',
          exp: Date.now() / 1000 + 60,
        });
      const client = createSocket();
      await gateway.identify({ token: 'first' }, client as never, jest.fn());
      client.rooms.add('server:old');
      let finishLeave!: () => void;
      client.leave.mockImplementationOnce(
        (room: string) =>
          new Promise<void>((resolve) => {
            finishLeave = () => {
              client.rooms.delete(room);
              resolve();
            };
          }),
      );

      const switching = gateway.identify(
        { token: 'second' },
        client as never,
        jest.fn(),
      );
      await new Promise((resolve) => setImmediate(resolve));
      expect(client.data.userId).toBeUndefined();
      expect(getActiveSocketIdentity(client as never)).toBeNull();
      finishLeave();
      await switching;
      expect(client.data.userId).toBe('user-2');
      expect(client.rooms.has('server:old')).toBe(false);
    });

    it('does not let a delayed old join remove the new account room', async () => {
      jwtService.verifyAsync.mockImplementation((token: string) => ({
        sub: token === 'old' ? 'user-1' : 'user-2',
        email: `${token}@plums.test`,
        exp: Date.now() / 1000 + 60,
      }));
      const serverGateway = new ServersGateway({
        serverMember: {
          findUnique: jest.fn().mockResolvedValue({ id: 'member' }),
        },
      } as unknown as PrismaService);
      const client = createSocket();
      await gateway.identify({ token: 'old' }, client as never, jest.fn());

      let finishOldJoin!: () => void;
      client.join
        .mockImplementationOnce(
          (room: string) =>
            new Promise<void>((resolve) => {
              finishOldJoin = () => {
                client.rooms.add(room);
                resolve();
              };
            }),
        )
        .mockImplementation((room: string) => {
          client.rooms.add(room);
        });
      const oldJoin = serverGateway.joinServer(
        { serverId: 'shared' },
        client as never,
      );
      await new Promise((resolve) => setImmediate(resolve));

      const switching = gateway.identify(
        { token: 'new' },
        client as never,
        jest.fn(),
      );
      await new Promise((resolve) => setImmediate(resolve));
      expect(client.data.userId).toBeUndefined();
      finishOldJoin();
      await Promise.all([oldJoin, switching]);
      await serverGateway.joinServer({ serverId: 'shared' }, client as never);

      expect(client.data.userId).toBe('user-2');
      expect(client.rooms.has('server:shared')).toBe(true);
    });
  });
});
