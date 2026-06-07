import { ForbiddenException, Injectable, NotFoundException } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { CreateServerDto } from './dto/create-server.dto';

@Injectable()
export class ServersService {
  constructor(private readonly prisma: PrismaService) {}

  async createServer(ownerId: string, dto: CreateServerDto) {
    return this.prisma.server.create({
      data: {
        name: dto.name,
        iconUrl: dto.iconUrl,
        ownerId,
        members: {
          create: {
            userId: ownerId,
          },
        },
      },
      include: {
        members: true,
      },
    });
  }

  async getMyServers(userId: string) {
    return this.prisma.server.findMany({
      where: {
        members: {
          some: {
            userId,
          },
        },
      },
      orderBy: {
        createdAt: 'asc',
      },
      select: {
        id: true,
        name: true,
        iconUrl: true,
        ownerId: true,
        createdAt: true,
        updatedAt: true,
      },
    });
  }

  async getServerById(userId: string, serverId: string) {
    const server = await this.prisma.server.findUnique({
      where: {
        id: serverId,
      },
      include: {
        members: {
          include: {
            user: {
              select: {
                id: true,
                username: true,
                email: true,
                avatarUrl: true,
                status: true,
                bio: true,
              },
            },
          },
        },
      },
    });

    if (!server) {
      throw new NotFoundException('Сервер не найден');
    }

    const isMember = server.members.some((member) => member.userId === userId);

    if (!isMember) {
      throw new ForbiddenException('У вас нет доступа к этому серверу');
    }

    return server;
  }
}
