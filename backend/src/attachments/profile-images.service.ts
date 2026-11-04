import {
  BadRequestException,
  ForbiddenException,
  Inject,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import sharp from 'sharp';
import { PrismaService } from '../prisma/prisma.service';
import { PermissionsService } from '../permissions/permissions.service';
import {
  UsersGateway,
  getActiveSocketIdentity,
  isSocketIdentityCurrent,
} from '../users/users.gateway';
import {
  ATTACHMENT_STORAGE,
  type AttachmentStorage,
} from './local-attachment-storage';
import { AttachmentsService, MAX_IMAGE_BYTES } from './attachments.service';

type Target = { userId: string } | { serverId: string };
type Upload = { buffer: Buffer; originalname: string; size: number };

@Injectable()
export class ProfileImagesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly permissions: PermissionsService,
    private readonly gateway: UsersGateway,
    private readonly attachments: AttachmentsService,
    @Inject(ATTACHMENT_STORAGE) private readonly storage: AttachmentStorage,
  ) {}

  async set(target: Target, actor: string, file?: Upload) {
    await this.authorize(target, actor);
    if (
      !file ||
      !Buffer.isBuffer(file.buffer) ||
      !file.buffer.length ||
      file.buffer.length > MAX_IMAGE_BYTES
    ) {
      throw new BadRequestException(
        'Размер изображения должен быть от 1 байта до 10 МБ',
      );
    }
    let bytes: Buffer;
    let mimeType: string;
    try {
      const image = sharp(file.buffer, {
        limitInputPixels: 40_000_000,
        failOn: 'error',
        animated: false,
      });
      const metadata = await image.metadata();
      if (
        !metadata.width ||
        !metadata.height ||
        metadata.width * metadata.height > 40_000_000 ||
        (metadata.pages ?? 1) > 1
      )
        throw new Error('Invalid image');
      if (metadata.format === 'jpeg') {
        mimeType = 'image/jpeg';
        bytes = await image.rotate().jpeg().toBuffer();
      } else if (metadata.format === 'png') {
        mimeType = 'image/png';
        bytes = await image.rotate().png().toBuffer();
      } else if (metadata.format === 'webp') {
        mimeType = 'image/webp';
        bytes = await image.rotate().webp().toBuffer();
      } else throw new Error('Unsupported image');
    } catch {
      throw new BadRequestException(
        'Поддерживаются корректные изображения JPEG, PNG и WebP',
      );
    }
    if (!bytes.length || bytes.length > MAX_IMAGE_BYTES)
      throw new BadRequestException(
        'Размер обработанного изображения превышает 10 МБ',
      );
    const storageKey = await this.storage.put(bytes);
    let result: { url: string; revision: number };
    try {
      await this.authorize(target, actor);
      result = await this.prisma.$transaction(async (tx) => {
        if ('userId' in target)
          await tx.$queryRaw`SELECT id FROM users WHERE id = ${target.userId} FOR UPDATE`;
        else
          await tx.$queryRaw`SELECT id FROM servers WHERE id = ${target.serverId} FOR UPDATE`;
        await tx.profileImage.deleteMany({ where: target });
        const image = await tx.profileImage.create({
          data: { ...target, mimeType, sizeBytes: bytes.length, storageKey },
        });
        const value = `/profile-images/${image.id}/content`;
        const updated =
          'userId' in target
            ? await tx.user.update({
                where: { id: target.userId },
                data: {
                  avatarUrl: value,
                  profileImageRevision: { increment: 1 },
                },
                select: { profileImageRevision: true },
              })
            : await tx.server.update({
                where: { id: target.serverId },
                data: {
                  iconUrl: value,
                  profileImageRevision: { increment: 1 },
                },
                select: { profileImageRevision: true },
              });
        return { url: value, revision: updated.profileImageRevision };
      });
    } catch (error) {
      try {
        // A connection error can occur after the transaction committed. Only
        // remove the file when the database confirms it is unreferenced.
        const persisted = await this.prisma.profileImage.findUnique({
          where: { storageKey },
          select: { id: true },
        });
        if (!persisted) await this.storage.remove(storageKey);
      } catch {
        /* orphan sweep retries once the database is available */
      }
      throw error;
    }
    void this.attachments.cleanup();
    await this.notify(target, result.url, result.revision);
    return result;
  }

  async remove(target: Target, actor: string) {
    await this.authorize(target, actor);
    const revision = await this.prisma.$transaction(async (tx) => {
      if ('userId' in target)
        await tx.$queryRaw`SELECT id FROM users WHERE id = ${target.userId} FOR UPDATE`;
      else
        await tx.$queryRaw`SELECT id FROM servers WHERE id = ${target.serverId} FOR UPDATE`;
      await tx.profileImage.deleteMany({ where: target });
      const updated =
        'userId' in target
          ? await tx.user.update({
              where: { id: target.userId },
              data: { avatarUrl: null, profileImageRevision: { increment: 1 } },
              select: { profileImageRevision: true },
            })
          : await tx.server.update({
              where: { id: target.serverId },
              data: { iconUrl: null, profileImageRevision: { increment: 1 } },
              select: { profileImageRevision: true },
            });
      return updated.profileImageRevision;
    });
    void this.attachments.cleanup();
    await this.notify(target, null, revision);
    return { url: null, revision };
  }

  async content(id: string, actor: string) {
    const image = await this.prisma.profileImage.findUnique({ where: { id } });
    if (!image) throw new NotFoundException('Изображение не найдено');
    if (image.serverId) {
      const member = await this.prisma.serverMember.findUnique({
        where: { serverId_userId: { serverId: image.serverId, userId: actor } },
        select: { id: true },
      });
      if (!member) throw new ForbiddenException('Нет доступа к серверу');
    }
    try {
      return {
        buffer: await this.storage.read(image.storageKey),
        mimeType: image.mimeType,
      };
    } catch {
      throw new NotFoundException('Изображение не найдено');
    }
  }

  private async authorize(target: Target, actor: string) {
    if ('userId' in target) {
      if (target.userId !== actor)
        throw new ForbiddenException('Нет доступа к профилю');
      if (
        !(await this.prisma.user.findUnique({
          where: { id: actor },
          select: { id: true },
        }))
      )
        throw new NotFoundException('Пользователь не найден');
    } else {
      await this.permissions.assertPermission(
        actor,
        target.serverId,
        'manageServer',
        'Нет права управлять сервером',
      );
    }
  }

  private async notify(target: Target, url: string | null, revision: number) {
    const sockets = this.gateway.server?.sockets?.sockets;
    if (!sockets) return;
    for (const socket of sockets.values()) {
      const identity = getActiveSocketIdentity(socket);
      if (!identity) continue;
      try {
        if ('serverId' in target) {
          const member = await this.prisma.serverMember.findUnique({
            where: {
              serverId_userId: {
                serverId: target.serverId,
                userId: identity.userId,
              },
            },
            select: { id: true },
          });
          if (!member) continue;
        }
        if (isSocketIdentityCurrent(socket, identity))
          socket.emit('profile-image:update', { ...target, url, revision });
      } catch {
        /* notification failure does not undo persisted changes */
      }
    }
  }
}
