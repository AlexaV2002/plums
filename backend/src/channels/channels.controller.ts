import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { ChannelsService } from './channels.service';
import { CreateChannelDto } from './dto/create-channel.dto';
import { UpdateChannelPermissionsDto } from './dto/update-channel-permissions.dto';
import { UpdateChannelDto } from './dto/update-channel.dto';

type JwtPayload = {
  sub: string;
  email: string;
};

@Controller()
@UseGuards(JwtAuthGuard)
export class ChannelsController {
  constructor(private readonly channelsService: ChannelsService) {}

  @Post('servers/:serverId/channels')
  createChannel(
    @CurrentUser() user: JwtPayload,
    @Param('serverId') serverId: string,
    @Body() dto: CreateChannelDto,
  ) {
    return this.channelsService.createChannel(user.sub, serverId, dto);
  }

  @Get('servers/:serverId/channels')
  getServerChannels(
    @CurrentUser() user: JwtPayload,
    @Param('serverId') serverId: string,
  ) {
    return this.channelsService.getServerChannels(user.sub, serverId);
  }

  @Patch('channels/:channelId')
  updateChannel(
    @CurrentUser() user: JwtPayload,
    @Param('channelId') channelId: string,
    @Body() dto: UpdateChannelDto,
  ) {
    return this.channelsService.updateChannel(user.sub, channelId, dto);
  }

  @Delete('channels/:channelId')
  deleteChannel(
    @CurrentUser() user: JwtPayload,
    @Param('channelId') channelId: string,
  ) {
    return this.channelsService.deleteChannel(user.sub, channelId);
  }

  @Patch('channels/:channelId/permissions')
  updateChannelPermissions(
    @CurrentUser() user: JwtPayload,
    @Param('channelId') channelId: string,
    @Body() dto: UpdateChannelPermissionsDto,
  ) {
    return this.channelsService.updateChannelPermissions(
      user.sub,
      channelId,
      dto,
    );
  }
}
