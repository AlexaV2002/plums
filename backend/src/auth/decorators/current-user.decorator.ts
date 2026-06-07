import { createParamDecorator, ExecutionContext } from '@nestjs/common';

type JwtPayload = {
  sub: string;
  email: string;
};

export const CurrentUser = createParamDecorator(
  (_data: unknown, ctx: ExecutionContext): JwtPayload => {
    const request = ctx.switchToHttp().getRequest();

    return request.user;
  },
);
