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
import { CreateRoleDto } from './dto/create-role.dto';
import { UpdateRoleDto } from './dto/update-role.dto';
import { RolesService } from './roles.service';

type JwtPayload = {
  sub: string;
  email: string;
};

@UseGuards(JwtAuthGuard)
@Controller()
export class RolesController {
  constructor(private readonly rolesService: RolesService) {}

  @Post('servers/:serverId/roles')
  createRole(
    @CurrentUser() user: JwtPayload,
    @Param('serverId') serverId: string,
    @Body() dto: CreateRoleDto,
  ) {
    return this.rolesService.createRole(user.sub, serverId, dto);
  }

  @Get('servers/:serverId/roles')
  getServerRoles(
    @CurrentUser() user: JwtPayload,
    @Param('serverId') serverId: string,
  ) {
    return this.rolesService.getServerRoles(user.sub, serverId);
  }

  @Patch('roles/:roleId')
  updateRole(
    @CurrentUser() user: JwtPayload,
    @Param('roleId') roleId: string,
    @Body() dto: UpdateRoleDto,
  ) {
    return this.rolesService.updateRole(user.sub, roleId, dto);
  }

  @Delete('roles/:roleId')
  deleteRole(@CurrentUser() user: JwtPayload, @Param('roleId') roleId: string) {
    return this.rolesService.deleteRole(user.sub, roleId);
  }

  @Post('servers/:serverId/members/:memberId/roles/:roleId')
  assignRole(
    @CurrentUser() user: JwtPayload,
    @Param('serverId') serverId: string,
    @Param('memberId') memberId: string,
    @Param('roleId') roleId: string,
  ) {
    return this.rolesService.assignRole(user.sub, serverId, memberId, roleId);
  }

  @Delete('servers/:serverId/members/:memberId/roles/:roleId')
  unassignRole(
    @CurrentUser() user: JwtPayload,
    @Param('serverId') serverId: string,
    @Param('memberId') memberId: string,
    @Param('roleId') roleId: string,
  ) {
    return this.rolesService.unassignRole(
      user.sub,
      serverId,
      memberId,
      roleId,
    );
  }
}
