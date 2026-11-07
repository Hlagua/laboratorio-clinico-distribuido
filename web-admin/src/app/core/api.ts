import { inject, Injectable, signal } from '@angular/core';
import { HttpClient, HttpErrorResponse, HttpInterceptorFn, HttpResponse } from '@angular/common/http';
import { Router } from '@angular/router';
import { firstValueFrom, tap } from 'rxjs';
import { AuthService } from './auth';

/** Estado del sistema visto en la última respuesta (cabeceras de la API). */
@Injectable({ providedIn: 'root' })
export class EstadoSistema {
  readonly origenDatos = signal<'azure' | 'supabase' | null>(null);
  readonly instancia = signal<string | null>(null);
  readonly vm = signal<string | null>(null);
}

/** Agrega el token y el rol activo; registra el origen de datos; cierra sesión ante 401. */
export const apiInterceptor: HttpInterceptorFn = (req, next) => {
  const auth = inject(AuthService);
  const estado = inject(EstadoSistema);
  const router = inject(Router);
  const token = auth.token();
  const rol = auth.rolActivo();
  if (token && req.url.startsWith('/api/') && !req.url.startsWith('/api/auth/login')) {
    req = req.clone({
      setHeaders: { Authorization: `Bearer ${token}`, ...(rol ? { 'X-Rol-Activo': rol } : {}) },
    });
  }
  return next(req).pipe(
    tap({
      next: (ev) => {
        if (ev instanceof HttpResponse) {
          const origen = ev.headers.get('X-Origen-Datos');
          if (origen === 'azure' || origen === 'supabase') estado.origenDatos.set(origen);
          estado.instancia.set(ev.headers.get('X-Instancia'));
          estado.vm.set(ev.headers.get('X-VM'));
        }
      },
      error: (e: HttpErrorResponse) => {
        if (e.status === 503 && e.error?.codigo === 'MODO_CONTINGENCIA') estado.origenDatos.set('supabase');
        if (e.status === 401 && token && !req.url.startsWith('/api/auth/login')) {
          auth.logout();
          router.navigateByUrl('/login');
        }
      },
    }),
  );
};

/** Traduce cualquier error HTTP a un mensaje legible para el usuario. */
export function mensajeError(e: unknown): string {
  if (e instanceof HttpErrorResponse) {
    if (e.status === 0) return 'No hay conexión con el servidor.';
    return e.error?.error ?? `Error ${e.status}`;
  }
  return e instanceof Error ? e.message : 'Error inesperado.';
}

/** Cliente de la API REST basado en promesas (más simple para las pantallas). */
@Injectable({ providedIn: 'root' })
export class Api {
  private readonly http = inject(HttpClient);

  get<T>(url: string, params?: Record<string, string | number | null | undefined>): Promise<T> {
    const limpios: Record<string, string> = {};
    for (const [k, v] of Object.entries(params ?? {})) {
      if (v !== null && v !== undefined && v !== '') limpios[k] = String(v);
    }
    return firstValueFrom(this.http.get<T>(url, { params: limpios }));
  }

  post<T>(url: string, cuerpo: unknown = {}): Promise<T> {
    return firstValueFrom(this.http.post<T>(url, cuerpo));
  }

  patch<T>(url: string, cuerpo: unknown): Promise<T> {
    return firstValueFrom(this.http.patch<T>(url, cuerpo));
  }

  delete<T>(url: string): Promise<T> {
    return firstValueFrom(this.http.delete<T>(url));
  }

  /** Descarga un archivo protegido (PDF) y lo abre en otra pestaña. */
  async abrirArchivo(url: string): Promise<void> {
    const blob = await firstValueFrom(this.http.get(url, { responseType: 'blob' }));
    const enlace = URL.createObjectURL(blob);
    window.open(enlace, '_blank');
    setTimeout(() => URL.revokeObjectURL(enlace), 60_000);
  }
}
