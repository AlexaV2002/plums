import {
  ConflictException,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { Prisma } from '@prisma/client';
import * as argon2 from 'argon2';
import { createHash, randomBytes } from 'crypto';
import { PrismaService } from '../prisma/prisma.service';
import { UsersService } from '../users/users.service';
import { LoginDto } from './dto/login.dto';
import { RefreshTokenDto } from './dto/refresh-token.dto';
import { RegisterDto } from './dto/register.dto';

const REFRESH_TOKEN_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 дней

@Injectable()
export class AuthService {
  constructor(
    private readonly usersService: UsersService,
    private readonly jwtService: JwtService,
    private readonly prisma: PrismaService,
  ) {}

  private hashToken(token: string) {
    return createHash('sha256').update(token).digest('hex');
  }

  private generateAccessToken(user: { id: string; email: string }) {
    return this.jwtService.signAsync(
      {
        sub: user.id,
        email: user.email,
      },
      {
        secret: process.env.JWT_SECRET,
        expiresIn: '15m',
      },
    );
  }

  private async issueRefreshToken(
    userId: string,
    prisma: Prisma.TransactionClient = this.prisma,
  ) {
    const refreshToken = randomBytes(48).toString('base64url');

    await prisma.refreshToken.create({
      data: {
        userId,
        tokenHash: this.hashToken(refreshToken),
        expiresAt: new Date(Date.now() + REFRESH_TOKEN_TTL_MS),
      },
    });

    return refreshToken;
  }

  private async issueTokenPair(user: { id: string; email: string }) {
    const [accessToken, refreshToken] = await Promise.all([
      this.generateAccessToken(user),
      this.issueRefreshToken(user.id),
    ]);

    return { accessToken, refreshToken };
  }

  async register(dto: RegisterDto) {
    const existingUser = await this.usersService.findByEmail(dto.email);

    if (existingUser) {
      throw new ConflictException('Пользователь с таким email уже существует');
    }

    const passwordHash = await argon2.hash(dto.password);

    const user = await this.usersService.createUser({
      username: dto.username,
      email: dto.email,
      passwordHash,
    });

    return {
      message: 'Пользователь успешно зарегистрирован',
      user,
    };
  }

  async login(dto: LoginDto) {
    const user = await this.usersService.findByEmail(dto.email);

    if (!user) {
      throw new UnauthorizedException('Неверный email или пароль');
    }

    const isPasswordValid = await argon2.verify(
      user.passwordHash,
      dto.password,
    );

    if (!isPasswordValid) {
      throw new UnauthorizedException('Неверный email или пароль');
    }

    const { accessToken, refreshToken } = await this.issueTokenPair(user);

    return {
      message: 'Вход выполнен успешно',
      accessToken,
      refreshToken,
      user: this.usersService.toPublicUser(user),
    };
  }

  async refresh(dto: RefreshTokenDto) {
    const tokenHash = this.hashToken(dto.refreshToken);

    const storedToken = await this.prisma.refreshToken.findUnique({
      where: { tokenHash },
      include: { user: true },
    });

    if (
      !storedToken ||
      storedToken.revokedAt ||
      storedToken.expiresAt <= new Date()
    ) {
      throw new UnauthorizedException(
        'Недействительный или истёкший refresh-токен',
      );
    }

    // Подписываем JWT до транзакции: при ошибке подписи старый токен останется рабочим.
    const accessToken = await this.generateAccessToken(storedToken.user);
    const refreshToken = await this.prisma.$transaction(async (tx) => {
      // Условный UPDATE блокирует строку в PostgreSQL. После первой ротации
      // конкурирующий запрос получит count = 0 и ответит 401.
      const claimed = await tx.refreshToken.updateMany({
        where: {
          id: storedToken.id,
          revokedAt: null,
          expiresAt: { gt: new Date() },
        },
        data: { revokedAt: new Date() },
      });
      if (claimed.count !== 1) {
        throw new UnauthorizedException(
          'Недействительный или истёкший refresh-токен',
        );
      }

      return this.issueRefreshToken(storedToken.user.id, tx);
    });

    return {
      accessToken,
      refreshToken,
      user: this.usersService.toPublicUser(storedToken.user),
    };
  }

  async logout(dto: RefreshTokenDto) {
    const tokenHash = this.hashToken(dto.refreshToken);

    await this.prisma.refreshToken.updateMany({
      where: { tokenHash, revokedAt: null },
      data: { revokedAt: new Date() },
    });

    return {
      message: 'Вы вышли из аккаунта',
    };
  }
}
