import { IsBoolean, IsOptional } from 'class-validator';

export class UpdateChannelPermissionsDto {
  @IsOptional()
  @IsBoolean()
  canView?: boolean;

  @IsOptional()
  @IsBoolean()
  canSendMessages?: boolean;

  @IsOptional()
  @IsBoolean()
  canConnect?: boolean;
}