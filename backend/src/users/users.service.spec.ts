import { Test, TestingModule } from '@nestjs/testing';
import { PrismaService } from '../prisma/prisma.service';
import { UsersGateway } from './users.gateway';
import { UsersService } from './users.service';

describe('UsersService', () => {
  let service: UsersService;
  let prisma: {
    user: {
      findMany: jest.Mock;
    };
  };

  beforeEach(async () => {
    prisma = {
      user: {
        findMany: jest.fn(),
      },
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        UsersService,
        { provide: PrismaService, useValue: prisma },
        { provide: UsersGateway, useValue: {} },
      ],
    }).compile();

    service = module.get<UsersService>(UsersService);
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  describe('search', () => {
    it('searches by username case-insensitively, excludes the current user and limits results', async () => {
      const users = [
        {
          id: 'user-2',
          username: 'Alexa',
          avatarUrl: 'https://example.com/alex.png',
          status: 'online',
        },
      ];

      prisma.user.findMany.mockResolvedValue(users);

      const result = await service.search('alex', 'current-user-id', 5);

      expect(result).toBe(users);
      expect(prisma.user.findMany).toHaveBeenCalledWith({
        where: {
          username: { contains: 'alex', mode: 'insensitive' },
          NOT: { id: 'current-user-id' },
        },
        select: {
          id: true,
          username: true,
          avatarUrl: true,
          status: true,
        },
        orderBy: { username: 'asc' },
        take: 5,
      });
    });

    it('defaults limit to 10 when not provided', async () => {
      prisma.user.findMany.mockResolvedValue([]);

      await service.search('a', 'current-user-id');

      expect(prisma.user.findMany).toHaveBeenCalledWith(
        expect.objectContaining({ take: 10 }),
      );
    });
  });
});
