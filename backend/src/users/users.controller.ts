import { Body, Controller, Get, Patch, Query, UseGuards } from '@nestjs/common';
import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { JwtAuthGuard } from '../auth/guards/jwt-auth.guard';
import { SearchUsersQueryDto } from './dto/search-users-query.dto';
import { UpdateMeDto } from './dto/update-me.dto';
import { UsersService } from './users.service';

type JwtPayload = {
  sub: string;
  email: string;
};

@Controller('users')
export class UsersController {
  constructor(private readonly usersService: UsersService) {}

  @UseGuards(JwtAuthGuard)
  @Get('me')
  getMe(@CurrentUser() user: JwtPayload) {
    return this.usersService.findPublicById(user.sub);
  }

  @UseGuards(JwtAuthGuard)
  @Patch('me')
  updateMe(@CurrentUser() user: JwtPayload, @Body() dto: UpdateMeDto) {
    return this.usersService.updateMe(user.sub, dto);
  }

  @UseGuards(JwtAuthGuard)
  @Get('search')
  search(@CurrentUser() user: JwtPayload, @Query() query: SearchUsersQueryDto) {
    return this.usersService.search(query.q, user.sub, query.limit);
  }
}
