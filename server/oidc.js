import { createRemoteJWKSet, jwtVerify } from 'jose';

export function createOidcVerifier({ issuer, clientIds = [] }) {
  if (!issuer || !clientIds.length) return null;
  const normalizedIssuer = issuer.replace(/\/$/, '');
  const jwks = createRemoteJWKSet(
    new URL(`${normalizedIssuer}/protocol/openid-connect/certs`),
  );

  return async (token) => {
    const { payload } = await jwtVerify(token, jwks, {
      issuer: normalizedIssuer,
      audience: 'account',
      algorithms: ['RS256'],
    });
    if (typeof payload.sub !== 'string' || !payload.sub) {
      throw new Error('OIDC_SUBJECT_MISSING');
    }
    if (typeof payload.preferred_username !== 'string' || !payload.preferred_username) {
      throw new Error('OIDC_USERNAME_MISSING');
    }
    if (typeof payload.azp !== 'string' || !clientIds.includes(payload.azp)) {
      throw new Error('OIDC_CLIENT_NOT_ALLOWED');
    }
    return {
      subject: payload.sub,
      username: payload.preferred_username.trim().toLowerCase(),
      displayName: String(payload.name || payload.preferred_username).slice(0, 80),
    };
  };
}
