import {
  BadRequestException,
  ForbiddenException,
  Inject,
  Injectable,
  Logger,
  NotFoundException,
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';
import { AttachmentState, ChannelType } from '@prisma/client';
import sharp from 'sharp';
import { PrismaService } from '../prisma/prisma.service';
import {
  ATTACHMENT_STORAGE,
  type AttachmentStorage,
} from './local-attachment-storage';

export const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const MAX_IMAGE_PIXELS = 40_000_000;
const UPLOAD_TTL_MS = 24 * 60 * 60 * 1000;
const ORPHAN_GRACE_MS = 25 * 60 * 60 * 1000;
const publicAttachment = {
  id: true,
  originalName: true,
  mimeType: true,
  sizeBytes: true,
} as const;

// Multipart filenames are decoded as Latin-1 by the parser. Recover valid
// UTF-8 sent by clients while preserving already decoded or legacy names.
function decodeUploadFilename(value: string): string {
  if ([...value].some((character) => character.codePointAt(0)! > 255)) {
    return value;
  }
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(
      Buffer.from(value, 'latin1'),
    );
  } catch {
    return value;
  }
}

@Injectable()
export class AttachmentsService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(AttachmentsService.name);
  private timer?: NodeJS.Timeout;
  private cleaning = false;

  constructor(
    private readonly prisma: PrismaService,
    @Inject(ATTACHMENT_STORAGE) private readonly storage: AttachmentStorage,
  ) {}

  onModuleInit() {
    this.timer = setInterval(() => void this.cleanup(), 15 * 60 * 1000);
    this.timer.unref();
    void this.cleanup();
  }

  onModuleDestroy() {
    if (this.timer) clearInterval(this.timer);
  }

  private async requireChannel(
    channelId: string,
    userId: string,
    send: boolean,
  ) {
    const channel = await this.prisma.channel.findUnique({
      where: { id: channelId },
      include: { server: { select: { ownerId: true } } },
    });
    if (!channel) throw new NotFoundException('Канал не найден');
    const member = await this.prisma.serverMember.findUnique({
      where: { serverId_userId: { serverId: channel.serverId, userId } },
      select: { id: true },
    });
    if (!member) throw new ForbiddenException('Вы не состоите на этом сервере');
    if (channel.type !== ChannelType.TEXT)
      throw new BadRequestException(
        'Изображения доступны только в текстовых каналах',
      );
    const permissions =
      channel.permissions &&
      typeof channel.permissions === 'object' &&
      !Array.isArray(channel.permissions)
        ? (channel.permissions as {
            canView?: boolean;
            canSendMessages?: boolean;
          })
        : {};
    if (
      channel.server.ownerId !== userId &&
      (permissions.canView === false ||
        (send && permissions.canSendMessages === false))
    ) {
      throw new ForbiddenException('У вас нет доступа к этому каналу');
    }
    return channel;
  }

  async upload(
    channelId: string,
    userId: string,
    file?: { buffer: Buffer; originalname: string; size: number },
  ) {
    await this.requireChannel(channelId, userId, true);
    if (
      !file ||
      !Buffer.isBuffer(file.buffer) ||
      file.buffer.length === 0 ||
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
        limitInputPixels: MAX_IMAGE_PIXELS,
        failOn: 'error',
        animated: false,
      });
      const metadata = await image.metadata();
      if (
        !metadata.width ||
        !metadata.height ||
        metadata.width * metadata.height > MAX_IMAGE_PIXELS ||
        (metadata.pages ?? 1) > 1
      ) {
        throw new Error('Invalid image dimensions or animation');
      }
      if (metadata.format === 'jpeg') {
        mimeType = 'image/jpeg';
        bytes = await image.rotate().jpeg().toBuffer();
      } else if (metadata.format === 'png') {
        mimeType = 'image/png';
        bytes = await image.rotate().png().toBuffer();
      } else if (metadata.format === 'webp') {
        mimeType = 'image/webp';
        bytes = await image.rotate().webp().toBuffer();
      } else {
        throw new Error('Unsupported image format');
      }
    } catch {
      throw new BadRequestException(
        'Поддерживаются корректные изображения JPEG, PNG и WebP',
      );
    }
    if (bytes.length === 0 || bytes.length > MAX_IMAGE_BYTES) {
      throw new BadRequestException(
        'Размер обработанного изображения превышает 10 МБ',
      );
    }
    const filename =
      decodeUploadFilename(file.originalname ?? '')
        .replace(/\\/g, '/')
        .split('/')
        .pop() ?? '';
    const originalName =
      filename
        .replace(/[\x00-\x1f\x7f]/g, '')
        .trim()
        .slice(0, 200) || 'image';
    const storageKey = await this.storage.put(bytes);
    try {
      // Recheck after image processing and storage I/O: access may have changed.
      await this.requireChannel(channelId, userId, true);
      return await this.prisma.attachment.create({
        data: {
          ownerId: userId,
          channelId,
          originalName,
          mimeType,
          sizeBytes: bytes.length,
          storageKey,
          state: AttachmentState.UPLOADED,
          expiresAt: new Date(Date.now() + UPLOAD_TTL_MS),
        },
        select: publicAttachment,
      });
    } catch (error) {
      // If storage removal fails, the orphan sweep will retry after its grace period.
      try {
        await this.storage.remove(storageKey);
      } catch {
        this.logger.warn('Failed to remove failed upload');
      }
      throw error;
    }
  }

  async content(id: string, userId: string) {
    const item = await this.prisma.attachment.findUnique({
      where: { id },
      include: { message: { select: { deletedAt: true, channelId: true } } },
    });
    if (
      !item ||
      item.state !== AttachmentState.ATTACHED ||
      !item.message ||
      item.message.deletedAt ||
      item.message.channelId !== item.channelId
    ) {
      throw new NotFoundException('Изображение не найдено');
    }
    await this.requireChannel(item.channelId, userId, false);
    try {
      return {
        buffer: await this.storage.read(item.storageKey),
        mimeType: item.mimeType,
      };
    } catch {
      throw new NotFoundException('Изображение не найдено');
    }
  }

  async discard(id: string, userId: string) {
    const result = await this.prisma.attachment.deleteMany({
      where: {
        id,
        ownerId: userId,
        state: AttachmentState.UPLOADED,
        messageId: null,
      },
    });
    if (result.count !== 1) throw new NotFoundException('Загрузка не найдена');
    // The DB trigger queues the key. Failure does not lose cleanup work.
    void this.cleanup();
  }

  async cleanup() {
    if (this.cleaning) return;
    this.cleaning = true;
    try {
      await this.prisma.attachment.deleteMany({
        where: {
          state: AttachmentState.UPLOADED,
          expiresAt: { lte: new Date() },
        },
      });
      const queued = await this.prisma.attachmentCleanup.findMany({
        orderBy: { createdAt: 'asc' },
        take: 100,
      });
      for (const entry of queued) {
        try {
          await this.storage.remove(entry.storageKey);
          await this.prisma.attachmentCleanup.deleteMany({
            where: { storageKey: entry.storageKey },
          });
        } catch {
          await this.prisma.attachmentCleanup.updateMany({
            where: { storageKey: entry.storageKey },
            data: { attempts: { increment: 1 }, lastAttemptAt: new Date() },
          });
        }
      }
      for (const key of await this.storage.oldKeys(
        new Date(Date.now() - ORPHAN_GRACE_MS),
      )) {
        const [record, pending] = await Promise.all([
          this.prisma.attachment.findUnique({
            where: { storageKey: key },
            select: { id: true },
          }),
          this.prisma.attachmentCleanup.findUnique({
            where: { storageKey: key },
            select: { storageKey: true },
          }),
        ]);
        if (!record && !pending) await this.storage.remove(key);
      }
    } catch {
      this.logger.warn('Attachment cleanup failed; it will be retried');
    } finally {
      this.cleaning = false;
    }
  }
}
