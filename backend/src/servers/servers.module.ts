import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { PrismaModule } from '../prisma/prisma.module';
import { ServersController } from './servers.controller';
import { ServersService } from './servers.service';

@Module({
  imports: [PrismaModule, JwtModule],
  controllers: [ServersController],
  providers: [ServersService],
})
export class ServersModule {}
