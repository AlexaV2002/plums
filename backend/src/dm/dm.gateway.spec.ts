import { Test, TestingModule } from '@nestjs/testing';
import { JwtService } from '@nestjs/jwt';
import { PrismaService } from '../prisma/prisma.service';
import { UsersGateway } from '../users/users.gateway';
import { DmGateway } from './dm.gateway';

type MockSocket = {
  data: Record<string, unknown>;
  rooms: Set<string>;
  join: jest.Mock;
  leave: jest.Mock;
  emit: jest.Mock;
};

const conversationId = 'conversation-1';
const roomName = `dm:${conversationId}`;

describe('DmGateway', () => {
  let gateway: DmGateway;
  let prisma: { directConversation: { findUnique: jest.Mock } };
  let serverTo: jest.Mock;
  let roomEmitter: { emit: jest.Mock };

  function createSocket(): MockSocket {
    const socket: MockSocket = {
      data: {},
      rooms: new Set(['socket-1']),
      join: jest.fn(),
      leave: jest.fn(),
      emit: jest.fn(),
    };

    socket.join.mockImplementation((room: string) => {
      socket.rooms.add(room);
    });
    socket.leave.mockImplementation((room: string) => {
      socket.rooms.delete(room);
    });

    return socket;
  }

  function conversation(userA: string, userB: string) {
    return { id: conversationId, userA, userB };
  }

  beforeEach(async () => {
    prisma = { directConversation: { findUnique: jest.fn() } };

    const module: TestingModule = await Test.createTestingModule({
      providers: [DmGateway, { provide: PrismaService, useValue: prisma }],
    }).compile();

    gateway = module.get<DmGateway>(DmGateway);

    roomEmitter = { emit: jest.fn() };
    serverTo = jest.fn().mockReturnValue(roomEmitter);
    gateway.server = { to: serverTo } as never;
  });

  describe('dm:join', () => {
    it('should reject join before presence:identify', async () => {
      prisma.directConversation.findUnique.mockResolvedValue(
        conversation('user-a', 'user-b'),
      );

      const client = createSocket();
      await gateway.joinConversation({ conversationId }, client as never);

      expect(client.emit).toHaveBeenCalledWith(
        'dm:error',
        expect.objectContaining({
          conversationId,
          error: expect.stringContaining('presence:identify'),
        }),
      );
      expect(client.join).not.toHaveBeenCalled();
      expect(prisma.directConversation.findUnique).not.toHaveBeenCalled();
    });

    it('should accept join when the identified user is a participant', async () => {
      prisma.directConversation.findUnique.mockResolvedValue(
        conversation('user-a', 'user-b'),
      );

      const client = createSocket();
      client.data.userId = 'user-b';

      await gateway.joinConversation({ conversationId }, client as never);

      expect(client.join).toHaveBeenCalledWith(roomName);
      expect(client.emit).not.toHaveBeenCalledWith('dm:error', expect.anything());
    });

    it('should reject join for a user who is not a participant', async () => {
      prisma.directConversation.findUnique.mockResolvedValue(
        conversation('user-a', 'user-b'),
      );

      const client = createSocket();
      client.data.userId = 'user-c';

      await gateway.joinConversation({ conversationId }, client as never);

      expect(client.emit).toHaveBeenCalledWith(
        'dm:error',
        expect.objectContaining({ conversationId }),
      );
      expect(client.join).not.toHaveBeenCalled();
    });

    it('should reject join for an unknown conversation', async () => {
      prisma.directConversation.findUnique.mockResolvedValue(null);

      const client = createSocket();
      client.data.userId = 'user-a';

      await gateway.joinConversation({ conversationId }, client as never);

      expect(client.emit).toHaveBeenCalledWith(
        'dm:error',
        expect.objectContaining({
          conversationId,
          error: 'Диалог не найден',
        }),
      );
      expect(client.join).not.toHaveBeenCalled();
    });
  });

  describe('dm:leave', () => {
    it('should leave the conversation room', () => {
      const client = createSocket();
      client.rooms.add(roomName);

      gateway.leaveConversation({ conversationId }, client as never);

      expect(client.leave).toHaveBeenCalledWith(roomName);
      expect(client.rooms.has(roomName)).toBe(false);
    });
  });

  describe('realtime emitters', () => {
    it('should emit dm:new only to the conversation room', () => {
      const message = { id: 'message-1', content: 'hello' };

      gateway.emitMessageNew(conversationId, message);

      expect(serverTo).toHaveBeenCalledWith(roomName);
      expect(roomEmitter.emit).toHaveBeenCalledWith('dm:new', message);
    });

    it('should emit dm:delete with id and conversationId', () => {
      gateway.emitMessageDelete(conversationId, { id: 'message-1' });

      expect(serverTo).toHaveBeenCalledWith(roomName);
      expect(roomEmitter.emit).toHaveBeenCalledWith('dm:delete', {
        id: 'message-1',
        conversationId,
      });
    });
  });

  describe('reconnect scenario (identify -> dm:join)', () => {
    it('should accept dm:join after presence:identify acknowledged the user', async () => {
      const jwtService = {
        verifyAsync: jest
          .fn()
          .mockResolvedValue({ sub: 'user-a', email: 'user-a@plums.test' }),
      };
      const usersPrisma = { user: { update: jest.fn().mockResolvedValue({}) } };

      const usersModule: TestingModule = await Test.createTestingModule({
        providers: [
          UsersGateway,
          { provide: JwtService, useValue: jwtService },
          { provide: PrismaService, useValue: usersPrisma },
        ],
      }).compile();
      const usersGateway = usersModule.get<UsersGateway>(UsersGateway);
      usersGateway.server = { emit: jest.fn() } as never;

      const client = createSocket();
      const ack = jest.fn();

      // 1. Переподключение: клиент сначала подтверждает идентификацию.
      await usersGateway.identify({ token: 'valid-token' }, client as never, ack);
      expect(ack).toHaveBeenCalledWith({ userId: 'user-a' });

      // 2. Только затем вступает в комнату диалога.
      prisma.directConversation.findUnique.mockResolvedValue(
        conversation('user-a', 'user-b'),
      );
      await gateway.joinConversation({ conversationId }, client as never);

      expect(client.join).toHaveBeenCalledWith(roomName);
      expect(client.emit).not.toHaveBeenCalledWith('dm:error', expect.anything());
    });
  });
});
