import { Test, TestingModule } from '@nestjs/testing';
import { JwtService } from '@nestjs/jwt';
import { PrismaService } from '../prisma/prisma.service';
import { UsersGateway } from './users.gateway';

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
  let prisma: { user: { update: jest.Mock } };

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
    prisma = { user: { update: jest.fn().mockResolvedValue({}) } };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        UsersGateway,
        { provide: JwtService, useValue: jwtService },
        { provide: PrismaService, useValue: prisma },
      ],
    }).compile();

    gateway = module.get<UsersGateway>(UsersGateway);
    gateway.server = { emit: jest.fn() } as never;
  });

  describe('presence:identify', () => {
    it('should set client.data.userId and acknowledge identify', async () => {
      jwtService.verifyAsync.mockResolvedValue({
        sub: 'user-1',
        email: 'user-1@plums.test',
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

    it('should disconnect on invalid token and not acknowledge', async () => {
      jwtService.verifyAsync.mockRejectedValue(new Error('invalid token'));

      const client = createSocket();
      const ack = jest.fn();

      await gateway.identify({ token: 'bad-token' }, client as never, ack);

      expect(client.disconnect).toHaveBeenCalledWith(true);
      expect(client.data.userId).toBeUndefined();
      expect(ack).not.toHaveBeenCalled();
    });

    it('should leave old dm:* rooms when the account changes on the same socket', async () => {
      jwtService.verifyAsync
        .mockResolvedValueOnce({
          sub: 'user-1',
          email: 'user-1@plums.test',
        })
        .mockResolvedValueOnce({
          sub: 'user-2',
          email: 'user-2@plums.test',
        });

      const client = createSocket();
      // user-1 уже успел присоединиться к своим dm-комнатам.
      client.rooms.add('dm:conversation-1');
      client.rooms.add('dm:conversation-2');
      client.rooms.add('server:server-1');
      client.rooms.add('channel:channel-1');
      // Комнаты без защищённого префикса не трогаем.
      client.rooms.add('custom-room');

      await gateway.identify({ token: 'token-1' }, client as never, jest.fn());
      expect(client.data.userId).toBe('user-1');

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

    it('should not touch dm rooms when identifying for the first time', async () => {
      jwtService.verifyAsync.mockResolvedValue({
        sub: 'user-1',
        email: 'user-1@plums.test',
      });

      const client = createSocket();
      client.rooms.add('dm:conversation-1');

      await gateway.identify(
        { token: 'valid-token' },
        client as never,
        jest.fn(),
      );

      expect(client.leave).not.toHaveBeenCalled();
      expect(client.data.userId).toBe('user-1');
    });
  });
});
