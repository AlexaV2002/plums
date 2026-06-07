import { Body, Controller, Get, Param, Post, UseGuards } from '@nestjs/common';
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { CreateInviteDto } from './dto/create-invite.dto';
import { InvitesService } from './invites.service';

type JwtPayload = {
  sub: string;
  email: string;
};

@Controller()
@UseGuards(JwtAuthGuard)
export class InvitesController {
  constructor(private readonly invitesService: InvitesService) {}

  @Post('servers/:serverId/invites')
  createInvite(
    @CurrentUser() user: JwtPayload,
    @Param('serverId') serverId: string,
    @Body() dto: CreateInviteDto,
  ) {
    return this.invitesService.createInvite(user.sub, serverId, dto);
  }

  @Get('invites/:code')
  getInvite(@Param('code') code: string) {
    return this.invitesService.getInvite(code);
  }

  @Post('invites/:code/join')
  joinInvite(@CurrentUser() user: JwtPayload, @Param('code') code: string) {
    return this.invitesService.joinInvite(user.sub, code);
  }
}
