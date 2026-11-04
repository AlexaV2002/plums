import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { PrismaModule } from '../prisma/prisma.module';
import { PermissionsModule } from '../permissions/permissions.module';
import { AttachmentsController } from './attachments.controller';
import { AttachmentsService } from './attachments.service';
import {
  ATTACHMENT_STORAGE,
  LocalAttachmentStorage,
} from './local-attachment-storage';

@Module({
  imports: [PrismaModule, JwtModule, PermissionsModule],
  controllers: [AttachmentsController],
  providers: [
    AttachmentsService,
    LocalAttachmentStorage,
    { provide: ATTACHMENT_STORAGE, useExisting: LocalAttachmentStorage },
  ],
  exports: [AttachmentsService],
})
export class AttachmentsModule {}
