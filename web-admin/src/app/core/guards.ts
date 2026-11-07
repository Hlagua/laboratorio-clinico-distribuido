import { inject } from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';
import { AuthService, Rol } from './auth';

export const autenticado: CanActivateFn = () => {
  const auth = inject(AuthService);
  return auth.autenticado() ? true : inject(Router).parseUrl('/login');
};

/** Permite la ruta solo si el ROL ACTIVO está entre los indicados. */
export function conRol(...roles: Rol[]): CanActivateFn {
  return () => {
    const auth = inject(AuthService);
    if (!auth.autenticado()) return inject(Router).parseUrl('/login');
    return auth.tiene(...roles) ? true : inject(Router).parseUrl('/inicio');
  };
}
