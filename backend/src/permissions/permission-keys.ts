export const SERVER_PERMISSION_KEYS = [
  'manageServer',
  'manageChannels',
  'manageMembers',
  'manageBans',
  'manageInvites',
  'manageRoles',
] as const;

export type ServerPermissionKey = (typeof SERVER_PERMISSION_KEYS)[number];

export type ServerPermissionSet = Record<ServerPermissionKey, boolean>;
