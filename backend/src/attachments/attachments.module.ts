import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { PrismaModule } from '../prisma/prisma.module';
import { PermissionsModule } from '../permissions/permissions.module';
import { UsersModule } from '../users/users.module';
import { ProfileImagesController } from './profile-images.controller';
import { ProfileImagesService } from './profile-images.service';
import { AttachmentsController } from './attachments.controller';
import { AttachmentsService } from './attachments.service';
import {
  ATTACHMENT_STORAGE,
  LocalAttachmentStorage,
} from './local-attachment-storage';

@Module({
  imports: [PrismaModule, JwtModule, PermissionsModule, UsersModule],
  controllers: [AttachmentsController, ProfileImagesController],
  providers: [
    AttachmentsService,
    ProfileImagesService,
    LocalAttachmentStorage,
    { provide: ATTACHMENT_STORAGE, useExisting: LocalAttachmentStorage },
  ],
  exports: [AttachmentsService],
})
export class AttachmentsModule {}
