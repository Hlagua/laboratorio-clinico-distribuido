import { ApplicationConfig, provideBrowserGlobalErrorListeners } from '@angular/core';
import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { provideRouter, withComponentInputBinding, withNavigationErrorHandler } from '@angular/router';
import { routes } from './app.routes';
import { apiInterceptor } from './core/api';

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    // Si una sección no carga (por ejemplo, la pestaña quedó abierta durante un despliegue y pide
    // archivos de la versión anterior), se recarga la página en esa dirección en vez de quedarse trabada.
    provideRouter(routes, withComponentInputBinding(), withNavigationErrorHandler((e) => {
      const destino = '/admin' + (e.url.startsWith('/') ? e.url : '/' + e.url);
      const clave = 'recarga-' + destino;
      try {
        if (sessionStorage.getItem(clave)) return;   // ya se intentó: no recargar en bucle
        sessionStorage.setItem(clave, '1');
        setTimeout(() => sessionStorage.removeItem(clave), 10_000);
      } catch { /* sin almacenamiento */ }
      window.location.assign(destino);
    })),
    provideHttpClient(withInterceptors([apiInterceptor])),
  ],
};
