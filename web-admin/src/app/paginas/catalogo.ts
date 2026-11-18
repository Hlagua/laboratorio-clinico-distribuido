import { Component, computed, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { dinero, hoyIso, rango } from '../core/formato';
import { MedicoAgenda, TipoExamen } from '../core/modelos';
import { paginarLocal, Paginador } from '../core/paginador';

interface ParamNuevo { nombre: string; unidad: string; valor_ref_min: number | null; valor_ref_max: number | null; valor_ref_texto: string }

@Component({
  selector: 'app-catalogo',
  imports: [FormsModule, Paginador],
  template: `
    <h1>Catálogo y franjas</h1>
    <p class="sub">Exámenes ofrecidos y horarios de atención.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }

    <div class="card tabla-scroll">
      <div class="buscador"><input type="search" placeholder="Buscar por código, examen, categoría o muestra" [ngModel]="q()" (ngModelChange)="q.set($event); pag.set(1)" /></div>
      <table>
        <thead><tr><th>Código</th><th>Examen</th><th>Categoría</th><th>Muestra</th><th class="num">Precio</th><th>Parámetros (referencia)</th></tr></thead>
        <tbody>
          @for (t of vista().items; track t.tipo_examen_id) {
            <tr>
              <td>{{ t.codigo }}</td>
              <td><strong>{{ t.nombre }}</strong>@if (t.requiere_ayuno) { <span class="badge ambar">ayuno</span> }</td>
              <td>{{ t.categoria }}</td><td>{{ t.tipo_muestra }}</td><td class="num">{{ dinero(t.precio) }}</td>
              <td><small>@for (p of t.parametros; track p.parametro_id) {
                {{ p.nombre }} ({{ rango(p.valor_ref_min, p.valor_ref_max, p.valor_ref_texto) }} {{ p.unidad }})@if (!$last) {, }
              }</small></td>
            </tr>
          } @empty { <tr><td colspan="6" class="vacio">Ningún examen coincide.</td></tr> }
        </tbody>
      </table>
      <app-paginador [pagina]="vista()" (cambiar)="pag.set($event)" />
    </div>

    <div class="grid dos">
      <form class="card" (ngSubmit)="crearExamen()">
        <h2>Nuevo examen</h2>
        <div class="fila">
          <div class="campo"><label>Código</label><input name="c" [(ngModel)]="ex.codigo" required /></div>
          <div class="campo"><label>Nombre</label><input name="n" [(ngModel)]="ex.nombre" required /></div>
        </div>
        <div class="fila">
          <div class="campo"><label>Categoría</label><input name="ca" [(ngModel)]="ex.categoria" list="cats" required />
            <datalist id="cats">@for (c of categorias(); track c) { <option [value]="c"></option> }</datalist></div>
          <div class="campo"><label>Muestra</label><input name="m" [(ngModel)]="ex.tipo_muestra" required /></div>
          <div class="campo"><label>Precio USD</label><input type="number" step="0.01" name="p" [(ngModel)]="ex.precio" required /></div>
        </div>
        <label><input type="checkbox" name="a" [(ngModel)]="ex.requiere_ayuno" /> Requiere ayuno</label>
        <h3>Parámetros</h3>
        @for (p of ex.parametros; track $index) {
          <div class="fila mini">
            <input placeholder="Nombre" [name]="'pn' + $index" [(ngModel)]="p.nombre" />
            <input placeholder="Unidad" [name]="'pu' + $index" [(ngModel)]="p.unidad" />
            <input type="number" placeholder="Mín" [name]="'pmi' + $index" [(ngModel)]="p.valor_ref_min" />
            <input type="number" placeholder="Máx" [name]="'pma' + $index" [(ngModel)]="p.valor_ref_max" />
            <input placeholder="o texto (Negativo)" [name]="'pt' + $index" [(ngModel)]="p.valor_ref_texto" />
          </div>
        }
        <div class="fila">
          <button type="button" class="secundario chico" (click)="ex.parametros.push(param())">+ Parámetro</button>
          <button type="submit">Agregar al catálogo</button>
        </div>
      </form>

      <form class="card" (ngSubmit)="generarFranjas()">
        <h2>Generar franjas de atención</h2>
        <p class="muted">Lunes a sábado. Las franjas que ya existen no se duplican.</p>
        <div class="campo"><label for="fm">Agenda de</label>
          <select id="fm" name="fm" [(ngModel)]="fr.medico_id" (ngModelChange)="fr.capacidad = $event ? 1 : 3">
            <option [ngValue]="null">Laboratorio (toma de muestras)</option>
            @for (m of medicos(); track m.medico_id) { <option [ngValue]="m.medico_id">Dr(a). {{ m.nombre }} · {{ m.especialidad }}</option> }
          </select></div>
        <div class="fila">
          <div class="campo"><label>Desde</label><input type="date" name="d" [(ngModel)]="fr.desde" required /></div>
          <div class="campo"><label>Hasta</label><input type="date" name="h" [(ngModel)]="fr.hasta" required /></div>
        </div>
        <div class="fila">
          <div class="campo"><label>Hora inicio</label><input type="time" name="hi" [(ngModel)]="fr.hora_inicio" /></div>
          <div class="campo"><label>Hora fin</label><input type="time" name="hf" [(ngModel)]="fr.hora_fin" /></div>
        </div>
        <div class="fila">
          <div class="campo"><label>Minutos por franja</label><input type="number" name="im" [(ngModel)]="fr.intervalo_minutos" /></div>
          <div class="campo"><label>Pacientes por franja</label><input type="number" name="cp" [(ngModel)]="fr.capacidad" /></div>
        </div>
        <button type="submit">Generar</button>
      </form>
    </div>
  `,
  styles: `.dos { grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); } .mini input { width: 100%; flex: 1 1 80px; } h3 { margin-top: 14px; } .badge { margin-left: 6px; }`,
})
export class Catalogo implements OnInit {
  private readonly api = inject(Api);
  protected readonly dinero = dinero;
  protected readonly rango = rango;
  protected readonly catalogo = signal<TipoExamen[]>([]);
  protected readonly categorias = signal<string[]>([]);
  protected readonly q = signal('');
  protected readonly pag = signal(1);
  protected readonly vista = computed(() =>
    paginarLocal(this.catalogo(), this.pag(), this.q(), (t) => `${t.codigo} ${t.nombre} ${t.categoria} ${t.tipo_muestra}`));
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  protected ex = this.examenVacio();
  protected fr = { desde: hoyIso(), hasta: hoyIso(), hora_inicio: '07:00', hora_fin: '11:00', intervalo_minutos: 30, capacidad: 3,
    medico_id: null as number | null };
  protected readonly medicos = signal<MedicoAgenda[]>([]);

  ngOnInit() {
    this.cargar();
  }

  protected param(): ParamNuevo {
    return { nombre: '', unidad: '', valor_ref_min: null, valor_ref_max: null, valor_ref_texto: '' };
  }

  private examenVacio() {
    return { codigo: '', nombre: '', categoria: '', tipo_muestra: 'Sangre', precio: null as number | null, requiere_ayuno: false,
      parametros: [this.param()] };
  }

  async cargar() {
    try {
      this.medicos.set(await this.api.get<MedicoAgenda[]>('/api/citas/medicos'));
      const c = await this.api.get<TipoExamen[]>('/api/examenes/catalogo');
      this.catalogo.set(c);
      this.categorias.set([...new Set(c.map((t) => t.categoria))]);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async crearExamen() {
    const parametros = this.ex.parametros.filter((p) => p.nombre.trim()).map((p) => ({
      nombre: p.nombre.trim(), unidad: p.unidad || null, valor_ref_min: p.valor_ref_min, valor_ref_max: p.valor_ref_max,
      valor_ref_texto: p.valor_ref_texto || null,
    }));
    await this.ejecutar(async () => {
      await this.api.post('/api/examenes/catalogo', { ...this.ex, parametros });
      this.ex = this.examenVacio();
    }, 'Examen agregado al catálogo.');
  }

  async generarFranjas() {
    await this.ejecutar(async () => {
      const r = await this.api.post<{ franjas_creadas: number }>('/api/citas/franjas', this.fr);
      this.aviso.set(`${r.franjas_creadas} franjas creadas.`);
    }, '');
  }

  private async ejecutar(fn: () => Promise<unknown>, exito: string) {
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
