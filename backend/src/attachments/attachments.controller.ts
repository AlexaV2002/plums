import {
  Controller,
  Delete,
  Get,
  HttpCode,
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
import { AttachmentsService, MAX_IMAGE_BYTES } from './attachments.service';

@Controller()
@UseGuards(JwtAuthGuard)
export class AttachmentsController {
  constructor(private readonly attachments: AttachmentsService) {}

  @Post('channels/:channelId/attachments')
  @UseInterceptors(
    FileInterceptor('file', {
      limits: { fileSize: MAX_IMAGE_BYTES, files: 1 },
    }),
  )
  upload(
    @CurrentUser() user: { sub: string },
    @Param('channelId') channelId: string,
    @UploadedFile()
    file?: { buffer: Buffer; originalname: string; size: number },
  ) {
    return this.attachments.upload(channelId, user.sub, file);
  }

  @Delete('attachments/:id')
  @HttpCode(204)
  async discard(@CurrentUser() user: { sub: string }, @Param('id') id: string) {
    await this.attachments.discard(id, user.sub);
  }

  @Get('attachments/:id/content')
  async content(
    @CurrentUser() user: { sub: string },
    @Param('id') id: string,
    @Res({ passthrough: true }) response: Response,
  ) {
    const result = await this.attachments.content(id, user.sub);
    response.setHeader('Content-Type', result.mimeType);
    response.setHeader('Content-Disposition', 'inline');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Cache-Control', 'private, no-store');
    return new StreamableFile(result.buffer);
  }
}
