import { IsBoolean, IsOptional, IsString, MaxLength, MinLength } from 'class-validator';

export class CreateRoleDto {
  @IsString()
  @MinLength(1)
  @MaxLength(100)
  name!: string;

  @IsOptional()
  @IsString()
  @MaxLength(20)
  color?: string;

  @IsOptional()
  @IsBoolean()
  manageServer?: boolean;

  @IsOptional()
  @IsBoolean()
  manageChannels?: boolean;

  @IsOptional()
  @IsBoolean()
  manageMembers?: boolean;

  @IsOptional()
  @IsBoolean()
  manageBans?: boolean;

  @IsOptional()
  @IsBoolean()
  manageInvites?: boolean;

  @IsOptional()
  @IsBoolean()
  manageRoles?: boolean;
}
