import { Component, computed, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { Laboratorio } from '../core/modelos';

/**
 * Sucursales de la empresa (con su ubicación para "Cómo llegar") y laboratorios externos.
 * El paciente elige la sucursal al reservar; si elige un laboratorio externo, allá paga y sube el PDF.
 */
@Component({
  selector: 'app-sucursales',
  imports: [FormsModule],
  template: `
    <h1>Sucursales y laboratorios</h1>
    <p class="sub">Las sucursales son de la empresa: tienen turnos, laboratoristas y descuentos. Su ubicación se usa
      en el portal para el botón "Cómo llegar" (Google Maps). Los laboratorios externos son para quien se hace los
      exámenes en otro lado: allá paga y luego sube el PDF de sus resultados.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }

    <div class="card tabla-scroll">
      <h2>Sucursales de la empresa</h2>
      <table>
        <thead><tr><th>Sucursal</th><th>Dirección y teléfono</th><th>Ubicación</th><th></th></tr></thead>
        <tbody>
          @for (l of sucursales(); track l.laboratorio_id) {
            @if (editando()?.laboratorio_id === l.laboratorio_id) {
              <tr>
                <td><strong>{{ l.nombre }}</strong></td>
                <td><input maxlength="250" [(ngModel)]="ed.direccion" placeholder="Dirección" />
                  <input maxlength="10" inputmode="numeric" [(ngModel)]="ed.telefono" placeholder="Teléfono" /></td>
                <td><input type="number" step="0.000001" [(ngModel)]="ed.latitud" placeholder="Latitud" />
                  <input type="number" step="0.000001" [(ngModel)]="ed.longitud" placeholder="Longitud" /></td>
                <td><button class="chico" (click)="guardar(l)">Guardar</button>
                  <button class="secundario chico" (click)="editando.set(null)">Cancelar</button></td>
              </tr>
            } @else {
              <tr [class.inactiva]="!l.activo">
                <td><strong>{{ l.nombre }}</strong>@if (!l.activo) { <span class="badge gris">inactiva</span> }</td>
                <td>{{ l.direccion }}<br /><small class="muted">{{ l.telefono }}</small></td>
                <td>@if (l.latitud !== null) {
                    <a [href]="mapa(l)" target="_blank" rel="noopener">Ver en Google Maps</a>
                  } @else { <span class="muted">sin ubicación</span> }</td>
                <td><button class="secundario chico" (click)="editar(l)">Editar</button>
                  <button class="secundario chico" (click)="activar(l)">{{ l.activo ? 'Desactivar' : 'Activar' }}</button></td>
              </tr>
            }
          }
        </tbody>
      </table>
    </div>

    <div class="card tabla-scroll">
      <h2>Laboratorios externos</h2>
      <table>
        @for (l of externos(); track l.laboratorio_id) {
          <tr [class.inactiva]="!l.activo"><td><strong>{{ l.nombre }}</strong><br /><small class="muted">{{ l.direccion }} {{ l.telefono }}</small></td>
            <td><button class="secundario chico" (click)="activar(l)">{{ l.activo ? 'Desactivar' : 'Activar' }}</button></td></tr>
        } @empty { <tr><td class="vacio">No hay laboratorios externos.</td></tr> }
      </table>
    </div>

    <form class="card" (ngSubmit)="crear()">
      <h2>Agregar</h2>
      <div class="fila">
        <div class="campo"><label for="lp">Tipo</label>
          <select id="lp" name="lp" [(ngModel)]="nuevo.propio">
            <option [ngValue]="true">Sucursal de la empresa</option>
            <option [ngValue]="false">Laboratorio externo</option>
          </select></div>
        <div class="campo"><label for="ln">Nombre</label><input id="ln" name="ln" maxlength="150" [(ngModel)]="nuevo.nombre" required /></div>
      </div>
      <div class="fila">
        <div class="campo"><label for="ld">Dirección</label><input id="ld" name="ld" maxlength="250" [(ngModel)]="nuevo.direccion" /></div>
        <div class="campo"><label for="lt">Teléfono</label><input id="lt" name="lt" maxlength="10" inputmode="numeric" [(ngModel)]="nuevo.telefono" /></div>
      </div>
      @if (nuevo.propio) {
        <div class="fila">
          <div class="campo"><label for="la">Latitud</label><input id="la" name="la" type="number" step="0.000001" [(ngModel)]="nuevo.latitud" placeholder="-1.2417" /></div>
          <div class="campo"><label for="lo">Longitud</label><input id="lo" name="lo" type="number" step="0.000001" [(ngModel)]="nuevo.longitud" placeholder="-78.6197" /></div>
        </div>
        <small class="muted">En Google Maps: clic derecho sobre el lugar y copie los dos números (latitud, longitud).</small>
      }
      <div class="fila"><button type="submit" [disabled]="!nuevo.nombre.trim()">Agregar</button></div>
    </form>
  `,
  styles: `tr.inactiva td { opacity: .55; } td input { width: 100%; margin: 2px 0; } .badge { margin-left: 6px; }`,
})
export class Sucursales implements OnInit {
  private readonly api = inject(Api);
  protected readonly labs = signal<Laboratorio[]>([]);
  protected readonly sucursales = computed(() => this.labs().filter((l) => l.propio));
  protected readonly externos = computed(() => this.labs().filter((l) => !l.propio));
  protected readonly editando = signal<Laboratorio | null>(null);
  protected ed = { direccion: '', telefono: '', latitud: null as number | null, longitud: null as number | null };
  protected nuevo = this.vacio();
  protected readonly error = signal('');
  protected readonly aviso = signal('');

  ngOnInit() {
    this.cargar();
  }

  private vacio() {
    return { propio: true, nombre: '', direccion: '', telefono: '', latitud: null as number | null, longitud: null as number | null };
  }

  protected mapa(l: Laboratorio) {
    return `https://www.google.com/maps/search/?api=1&query=${l.latitud},${l.longitud}`;
  }

  private async cargar() {
    try {
      this.labs.set(await this.api.get<Laboratorio[]>('/api/laboratorios', { todos: 1 }));
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  protected editar(l: Laboratorio) {
    this.ed = { direccion: l.direccion ?? '', telefono: l.telefono ?? '', latitud: l.latitud, longitud: l.longitud };
    this.editando.set(l);
  }

  protected async guardar(l: Laboratorio) {
    await this.paso(async () => {
      await this.api.put(`/api/laboratorios/${l.laboratorio_id}`, {
        direccion: this.ed.direccion || null, telefono: this.ed.telefono || null, latitud: this.ed.latitud, longitud: this.ed.longitud,
      });
      this.editando.set(null);
    }, `${l.nombre} actualizada.`);
  }

  protected async activar(l: Laboratorio) {
    await this.paso(() => this.api.patch(`/api/laboratorios/${l.laboratorio_id}`, { activo: !l.activo }), '');
  }

  protected async crear() {
    const n = this.nuevo;
    await this.paso(async () => {
      await this.api.post('/api/laboratorios', {
        nombre: n.nombre, propio: n.propio, direccion: n.direccion || null, telefono: n.telefono || null,
        latitud: n.propio ? n.latitud : null, longitud: n.propio ? n.longitud : null,
      });
      this.nuevo = this.vacio();
    }, `${n.propio ? 'Sucursal' : 'Laboratorio'} ${n.nombre} agregado.`);
  }

  private async paso(fn: () => Promise<unknown>, exito: string) {
    this.error.set('');
    this.aviso.set('');
    try {
      await fn();
      if (exito) this.aviso.set(exito);
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
