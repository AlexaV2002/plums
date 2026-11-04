import {
  Controller,
  Delete,
  Get,
  Param,
  Post,
  Res,
  StreamableFile,
  UploadedFile,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import type { Response } from 'express';
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { MAX_IMAGE_BYTES } from './attachments.service';
import { ProfileImagesService } from './profile-images.service';

@Controller()
@UseGuards(JwtAuthGuard)
export class ProfileImagesController {
  constructor(private readonly images: ProfileImagesService) {}

  @Post('users/me/avatar')
  @UseInterceptors(
    FileInterceptor('file', {
      limits: { fileSize: MAX_IMAGE_BYTES, files: 1 },
    }),
  )
  avatar(
    @CurrentUser() user: { sub: string },
    @UploadedFile()
    file?: { buffer: Buffer; originalname: string; size: number },
  ) {
    return this.images.set({ userId: user.sub }, user.sub, file);
  }

  @Delete('users/me/avatar')
  removeAvatar(@CurrentUser() user: { sub: string }) {
    return this.images.remove({ userId: user.sub }, user.sub);
  }

  @Post('servers/:id/icon')
  @UseInterceptors(
    FileInterceptor('file', {
      limits: { fileSize: MAX_IMAGE_BYTES, files: 1 },
    }),
  )
  icon(
    @CurrentUser() user: { sub: string },
    @Param('id') id: string,
    @UploadedFile()
    file?: { buffer: Buffer; originalname: string; size: number },
  ) {
    return this.images.set({ serverId: id }, user.sub, file);
  }

  @Delete('servers/:id/icon')
  removeIcon(@CurrentUser() user: { sub: string }, @Param('id') id: string) {
    return this.images.remove({ serverId: id }, user.sub);
  }

  @Get('profile-images/:id/content')
  async content(
    @CurrentUser() user: { sub: string },
    @Param('id') id: string,
    @Res({ passthrough: true }) response: Response,
  ) {
    const image = await this.images.content(id, user.sub);
    response.setHeader('Content-Type', image.mimeType);
    response.setHeader('Content-Disposition', 'inline');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Cache-Control', 'private, no-store');
    return new StreamableFile(image.buffer);
  }
}
