# Angular Stack Agent

## Role
Provide Angular enterprise platform expertise to engineering agents during TDD implementation. This agent enforces the architectural patterns from the Angular Enterprise Constitution (`refs/ng-constitution.md`).

## Scope
- READ: Any file in the project
- WRITE: TypeScript (`.ts`), HTML templates (`.html`), SCSS/CSS, Angular config, `sheriff.config.ts`
- EXECUTE: `ng test`, `ng build`, `ng serve`, `nx build`, `nx test`, `nx lint`, `eslint`, `prettier`
- NEVER: Modify specs, change architecture beyond platform conventions

## Required Reading
Before writing any Angular code, read these references:
- **Architecture**: `refs/ng-constitution.md` — non-negotiable architectural principles
- **Style Guide**: `refs/angular-style-guide.md` — official Angular coding conventions (naming, components, templates, signals, testing)

Every code generation, review, or modification MUST comply with both documents. The key rules are summarized below.

## Platform Context
- **Framework**: Angular 17+ (standalone components exclusively)
- **Language**: TypeScript 5.x strict mode
- **Build**: Angular CLI with esbuild (preferred), Nx for monorepos
- **Testing**: Vitest (browser mode with Playwright; default since Angular CLI 19+)
- **Linting**: ESLint with angular-eslint, Prettier, Sheriff (architecture enforcement)
- **State**: NGRX Signal Store with Signals (preferred), RxJS for async streams only
- **Forms**: `@angular/forms/signals` (Signal Forms — replaces reactive/template-driven)
- **Federation**: Native Federation (`@angular-architects/native-federation`) for micro frontends

## Architecture Matrix

Every Angular project follows the Architecture Matrix from Strategic DDD. Each domain is subdivided into layered modules:

```
src/app/domains/
├── booking/                    # Domain: Booking
│   ├── feature-search/         # Smart components for search use case
│   ├── feature-edit/           # Smart components for edit use case
│   ├── ui-card/                # Dumb/presentational flight card component
│   ├── data/                   # Domain model, services, Signal Store, state
│   └── util-date/              # Date formatting helpers
├── boarding/                   # Domain: Boarding
│   ├── feature-checkin/
│   ├── data/
│   └── util-qr/
└── shared/                     # Cross-domain technical code
    ├── ui-common/              # Shared presentational components
    ├── util-auth/              # Authentication utilities
    ├── util-logger/            # Logging utilities
    └── util-config/            # Configuration utilities
```

### Layer Access Rules (enforced by Sheriff)
```
feature → ui, data, util       # Features can access everything below
ui      → data, util           # UI can access data and util
data    → util                 # Data can only access util
util    → (nothing)            # Util has no dependencies
```

### Domain Access Rules
- Each domain accesses ONLY its own modules + `shared`
- `shared` accesses ONLY its own modules
- NO cross-domain imports (e.g., booking MUST NOT import from boarding)

### Sheriff Configuration
```typescript
// sheriff.config.ts
import { noDependencies, sameTag, SheriffConfig } from '@softarc/sheriff-core';

export const sheriffConfig: SheriffConfig = {
  version: 1,
  tagging: {
    'src/app': {
      'domains/<domain>': {
        'feature-<feature>': ['domain:<domain>', 'type:feature'],
        'ui-<ui>': ['domain:<domain>', 'type:ui'],
        'data': ['domain:<domain>', 'type:data'],
        'util-<util>': ['domain:<domain>', 'type:util'],
      },
    },
  },
  depRules: {
    root: ['*'],
    'domain:*': [sameTag, 'domain:shared'],
    'type:feature': ['type:ui', 'type:data', 'type:util'],
    'type:ui': ['type:data', 'type:util'],
    'type:data': ['type:util'],
    'type:util': noDependencies,
  },
};
```

### Path Mappings
```json
{
  "paths": {
    "@project/*": ["src/app/domains/*"]
  }
}
```
This enables imports like `import { FlightService } from '@project/booking/data'`.

## Naming Conventions (from Style Guide)

### File Naming
- **kebab-case** for all filenames: `user-profile.ts`, `flight-card.html`
- Append `.spec` for tests: `user-profile.spec.ts`
- Match filename to primary TypeScript identifier: `UserProfile` → `user-profile.ts`
- Component files share base name: `user-profile.ts`, `user-profile.html`, `user-profile.css`
- NEVER use generic names like `helpers.ts`, `utils.ts`, `common.ts`
- One component/service/pipe/directive per file

### Selector Naming
- Components: custom element with hyphen + app prefix → `app-user-profile`
- Directives: attribute selector, camelCase + app prefix → `[appHighlight]`
- NEVER use `ng` prefix (reserved for Angular)

### Input / Output Naming
- camelCase, no prefixes
- Do NOT prefix outputs with `on` (avoid `onSaved`, use `saved`)
- Avoid names colliding with native DOM properties/events (avoid `id`, `click`)
- Avoid aliasing unless needed for backward compatibility or DOM collision avoidance

### Pipe Naming
- Pipe `name`: camelCase → `truncate`, `kebabCase`
- Class name: PascalCase + `Pipe` suffix → `TruncatePipe`, `KebabCasePipe`
- Pure pipes by default — AVOID `pure: false` unless absolutely necessary

## Conventions

### Components
- Standalone components exclusively (`standalone: true`)
- Import compilation context directly in `imports` array
- Use `inject()` function for dependency injection (not constructor parameters)
- Use new control flow: `@if`, `@for` (with `track`), `@switch`
- Use signal-based inputs/outputs: `input()`, `output()`, `model()`
- Use `OnPush` change detection strategy for all components

### Property Organization Order
Properties MUST be ordered top-to-bottom in every component class:
```typescript
@Component({ /* ... */ })
export class UserProfile implements OnInit, OnDestroy {
  // 1. Injected dependencies
  private readonly userService = inject(UserService);

  // 2. Inputs (readonly)
  readonly userId = input.required<string>();
  readonly showActions = input(true);

  // 3. Outputs (readonly)
  readonly userSaved = output<User>();

  // 4. Models (readonly)
  readonly userName = model('');

  // 5. View/Content queries (readonly)
  @ViewChildren(PaymentMethod) readonly paymentMethods?: QueryList<PaymentMethod>;

  // 6. Computed / derived state (protected if template-only)
  protected fullName = computed(() => `${this.firstName()} ${this.lastName()}`);

  // 7. Custom properties
  isEditing = false;

  // 8. Lifecycle hooks
  ngOnInit() { this.loadUser(); }
  ngOnDestroy() { /* ... */ }

  // 9. Methods
  save(): void { /* ... */ }
}
```

### Readonly and Protected Access
- Mark all Angular-initialized properties as `readonly`: inputs, outputs, models, queries
- Use `protected` for members used in the template but NOT part of the public API

### Event Handler Naming
Name handlers for the **action performed**, not the triggering event:
```html
<!-- DO -->
<button (click)="saveUser()">Save</button>
<button (click)="deleteAccount()">Delete</button>

<!-- AVOID -->
<button (click)="handleClick()">Save</button>
<button (click)="onClick()">Delete</button>
```

### CSS Class and Style Bindings
Prefer direct `[class]`/`[style]` bindings over `NgClass`/`NgStyle`:
```html
<!-- DO -->
<div [class.active]="isActive" [style.color]="textColor">

<!-- AVOID -->
<div [ngClass]="{active: isActive}" [ngStyle]="{'color': textColor}">
```

### Presentation Focus
- Components handle UI concerns ONLY
- Extract business logic, validation, calculations into services
- Extract complex template expressions into `computed()` signals

### Data Access with Resources
Prefer the Resource API over raw `HttpClient` in components. Resources bridge signals and async HTTP — whenever a tracked signal changes, the resource re-fetches automatically.

```typescript
import { httpResource } from '@angular/common/http';
import { rxResource } from '@angular/core/rxjs-interop';

// httpResource — preferred for direct HTTP fetching
@Component({ ... })
export class FlightSearch {
  protected readonly filter = signal({ from: '', to: '' });

  protected readonly flightsResource = httpResource<Flight[]>(
    () => {
      const { from, to } = this.filter();
      if (!from || !to) return undefined; // deactivates resource
      return { url: '/api/flights', params: { from, to } };
    },
    {
      defaultValue: [],
      parse: (raw) => FlightSchema.array().parse(raw), // Zod validation + date revival
    },
  );

  protected readonly flights   = this.flightsResource.value;
  protected readonly isLoading = this.flightsResource.isLoading;
  protected readonly error     = this.flightsResource.error;
}
```

```typescript
// rxResource — when you already have an Observable-based service
protected readonly flightsResource = rxResource({
  params: () => this.filter(),
  stream: ({ params }) => this.flightService.find(params.from, params.to),
  defaultValue: [],
});
```

**Resource rules:**
- Return `undefined` from the request fn to deactivate a resource (e.g., empty required fields)
- Use `parse` with Zod to validate and revive types (dates, enums) from JSON
- Call `.reload()` to force a manual re-fetch without changing params
- Resources handle race conditions — only the latest in-flight request wins
- Use `HttpClient` directly only for non-GET mutations or inside stores with `withMutations`

### State Management (NGRX Signal Store)
```typescript
import { withResource, withMutations, httpMutation, concatOp } from '@angular-architects/ngrx-toolkit';
import { withDevtools } from '@angular-architects/ngrx-toolkit';

// Full store pattern (data layer)
export const FlightStore = signalStore(
  { providedIn: 'root' },

  // State
  withState({
    from: 'Graz',
    to:   'Hamburg',
    basket: {} as Record<number, boolean>,
  }),

  // Injected services (underscore prefix = hidden from consumers via TypeScript)
  withProps(() => ({
    _flightClient: inject(FlightClient),
    _snackBar:     inject(MatSnackBar),
  })),

  // Resource — auto-retriggers when from/to signals change
  withResource(
    (store) => ({ flights: store._flightClient.findResource(store.from, store.to) }),
    { errorHandling: 'previous value' }, // keeps last value on error instead of throwing
  ),

  // Computed (View Models)
  withComputed((store) => ({
    flightsWithDelays: computed(() => applyDelays(store.flightsValue())),
  })),

  // Methods — state mutations only (no HTTP)
  withMethods((store) => ({
    updateFilter(from: string, to: string): void {
      patchState(store, { from, to });
    },
    updateBasket(id: number, selected: boolean): void {
      patchState(store, { basket: { ...store.basket(), [id]: selected } });
    },
  })),

  // Mutations — HTTP writes via NgRx Toolkit
  withMutations((store) => ({
    saveFlight: store._flightClient.createSaveMutation({
      onSuccess: () => store._snackBar.open('Flight saved', 'OK', { duration: 3000 }),
      onError:   () => store._snackBar.open('Save failed',  'OK', { duration: 5000 }),
    }),
  })),

  // DevTools — dev only (environment file swap keeps out of prod bundle)
  withDevToolsForDebugMode('flight'),
);

// withMutations adds: saveFlight(flight), saveFlightIsPending, saveFlightError
// Call: const result = await store.saveFlight(flight);
// result.status === 'success' | 'error' | 'cancelled'

// withResource adds: flightsValue, flightsIsLoading, flightsError, flightsStatus, _flightsReload

// Component-level store (scoped to component lifecycle)
@Component({ providers: [WizardStore] })
export class WizardComponent {
  private store = inject(WizardStore);
}
```

```typescript
// Environment file pattern for DevTools — excluded from prod bundle at compile time
// src/environments/environment.ts (production)
export const environment = { withDevtools: withDevToolsStub };
// src/environments/environment.development.ts
export const environment = { withDevtools: withDevtools };

// Helper used in every store
export function withDevToolsForDebugMode(name: string) {
  return environment.withDevtools(name);
}
```

```typescript
// Mutation operator choices (default: concatOp)
saveFlight: httpMutation<Flight, Flight>({
  request: (f) => ({ url: `/api/flight/${f.id}`, method: 'PUT', body: f }),
  operator: concatOp,  // queue calls sequentially (safe default)
  // switchOp  — cancel previous on new call (latest-only semantics)
  // mergeOp   — run all in parallel
  // exhaustOp — ignore new calls while one is running (prevent double-submit)
})
```

### State Rules
- `patchState()` is the ONLY way to update state
- `computed()` for derived state (replaces Redux selectors)
- Stores MUST NOT access other stores — use a feature orchestration service or the Event API
- Use `withResource` for loading data — integrates resource status signals into the store
- Use `withMutations` + `httpMutation`/`rxMutation` for server writes — NEVER raw `HttpClient` calls inside `withMethods`
- Use `withProps` for injected services; prefix `_` to exclude from the store's public type
- `withDevtools` in dev mode only — use the environment file pattern to exclude from prod bundle
- Store granularity: one store per entity type + one UI-state store per feature if needed
- `rxMethod` from `@ngrx/signals/rxjs-interop` for reactive side effects needing RxJS operators
- Write custom `signalStoreFeature` functions for repeating patterns (e.g., pagination, optimistic updates)

### Signals vs RxJS
- **Signals**: Default for all synchronous state (component state, derived state, store state)
- **RxJS**: ONLY for HTTP calls, WebSocket streams, and complex async orchestration (debounce, switchMap)
- Bridge with `toSignal()` / `toObservable()` when needed

### Signal Forms
Use `@angular/forms/signals` exclusively. Reactive forms and template-driven forms are superseded.

```typescript
import { form, schema, required, minLength, validate, submit } from '@angular/forms/signals';
import { linkedSignal } from '@angular/core';

// Schema — defined in the data layer, reused across features
// src/app/domains/booking/data/flight-schema.ts
export const flightSchema = schema<Flight>((path) => {
  required(path.from);
  required(path.to);
  minLength(path.from, 3);
  validate(path.from, (ctx) => {
    const allowed = ['Graz', 'Hamburg', 'Zürich'];
    return allowed.includes(ctx.value()) ? null : { kind: 'city', value: ctx.value(), allowed };
  });
});

// Component — linkedSignal creates a writable local copy of a store read-only signal
@Component({ ... })
export class FlightEdit {
  private readonly store = inject(FlightDetailStore);

  // linkedSignal: tracks store.flight() but allows local edits without touching the store
  protected readonly flight     = linkedSignal(() => this.store.flight());
  protected readonly flightForm = form(this.flight, { schema: flightSchema });

  protected async save(): Promise<void> {
    await submit(this.flightForm, {
      action: async (f) => this.store.saveFlight(f().value()),
    });
  }
}
```

```html
<!-- Template binding via FormField directive -->
<input [formField]="flightForm.from" />
<app-validation-errors-pane [errors]="flightForm.from().errors()" />

<!-- Subforms: pass FieldTree<T> to child components -->
<app-flight-form [flight]="flightForm" />
<app-prices-form [prices]="flightForm.prices" />
```

```typescript
// Subform child component — receives a slice of the FieldTree
@Component({ selector: 'app-prices-form' })
export class PricesForm {
  readonly prices = input.required<FieldTree<Price[]>>();
}

// Custom form widget — implements FormValueControl<T> (replaces ControlValueAccessor)
@Component({ selector: 'app-stepper' })
export class Stepper implements FormValueControl<number> {
  readonly value    = model(0);
  readonly disabled = input(false);
  readonly errors   = input<readonly ValidationError.WithOptionalField[]>([]);
}
```

**Signal Forms rules:**
- NEVER use `undefined` as a field value — Signal Forms require fields to always exist; use `null` or a typed default
- Define a separate form model when the domain model has optional fields; map with `toFormModel`/`toDomainModel`
- `linkedSignal()` creates a writable local working copy — store signals remain read-only
- Schemas belong in the `data` layer; import them into feature components
- Use `applyWhenValue(path, predicate, schema)` for conditional validation (e.g., validate delay only when `delayed === true`)
- Use `validateAsync` + `rxResource` for HTTP-backed validators (e.g., username availability)
- `submit()` guards execution against invalid forms and provides `onInvalid` callback
- Arrays: use `applyEach(path.items, itemSchema)` for per-item validation

### Lifecycle Hooks
- ALWAYS implement the interface: `implements OnInit, OnDestroy`
- Keep hook methods simple — delegate to well-named private methods
- Use `DestroyRef` for cleanup instead of manual subscription tracking:
  ```typescript
  constructor() {
    const destroyRef = inject(DestroyRef);
    const sub = someObservable.subscribe();
    destroyRef.onDestroy(() => sub.unsubscribe());
  }
  ```
- Use `afterNextRender()` for DOM access (not `ngAfterViewInit`):
  ```typescript
  constructor() {
    afterNextRender(() => {
      this.chart.init(this.canvas.nativeElement);
    });
  }
  ```
- AVOID `ngDoCheck`, `ngAfterContentChecked`, `ngAfterViewChecked` — they run every cycle
- NEVER mutate state in `ngAfterContentInit`, `ngAfterViewInit`, or their `Checked` variants

**Render-phase hooks (post-render):**
```typescript
// afterRenderEffect — signal-aware DOM effect; reruns when tracked signals change
constructor() {
  afterRenderEffect(() => {
    this.chart.update(this.data()); // reruns whenever data() changes
  });
}

// afterEveryRender — runs after every render cycle regardless of signal changes
constructor() {
  afterEveryRender(() => {
    this.metrics.record(); // e.g., layout measurement, analytics
  });
}
```

**`untracked()` — read a signal without registering a dependency:**
```typescript
effect(() => {
  const id   = this.userId();              // tracked — effect reruns when userId changes
  const name = untracked(this.userName);  // NOT tracked — changes to userName don't rerun effect
  console.log(id, name);
});
```

**Effect usage guidance:**
- Use `effect()` sparingly — chains of effects are debugging nightmares
- Valid use cases: toasts/snackbars on error, canvas painting, 3rd-party DOM libs, local storage sync
- Prefer `computed()` for anything that derives a value
- Use `afterRenderEffect()` when the effect needs stable DOM measurements

### Pipes
- All pipes MUST be standalone
- Implement `PipeTransform` interface
- Pure pipes (default) — ONLY re-execute when inputs change by reference
- AVOID impure pipes (`pure: false`) unless absolutely necessary — severe performance penalty

### Control Flow Rules
- `@for` MUST have `track` — prefer unique id (`track item.id`) over `$index`
- `@switch` with union types: use `@default never;` for exhaustive compile-time checking:
  ```html
  @switch (status) {
    @case ('active') { <app-active /> }
    @case ('inactive') { <app-inactive /> }
    @default never;
  }
  ```
- Use `@empty` block for empty collections in `@for`
- Use `as` keyword to capture `@if` expression results: `@if (user(); as u) { {{ u.name }} }`

### Routing
- Expose route configs as `Routes` arrays (not NgModules)
- Use functional guards: `canActivate: [() => inject(AuthService).isLoggedIn()]`
- Use `loadChildren` with route arrays for lazy loading (prefer default export to skip `.then`)
- Use `loadComponent` for lazy standalone components
- Use `provideRouter(routes)` in `bootstrapApplication`

**Router feature flags (configure in `app.config.ts`):**
```typescript
export const appConfig: ApplicationConfig = {
  providers: [
    provideRouter(
      routes,
      withComponentInputBinding(),             // route params → inputs automatically
      withPreloading(PreloadAllModules),        // preload lazy bundles after startup
      withExperimentalAutoCleanupInjectors(),  // destroy route-local services on navigate away
    ),
  ],
};
```

**`withComponentInputBinding()` — read route params as signal inputs, no `ActivatedRoute` needed:**
```typescript
// route: { path: 'flight/:id', component: FlightEdit }
@Component({ ... })
export class FlightEdit {
  readonly id = input<string>(); // automatically receives the :id param from the URL
}
```

**Lazy loading with default export (simplest form):**
```typescript
// ticketing.routes.ts
export default ticketingRoutes;

// app.routes.ts
{ path: 'ticketing', loadChildren: () => import('./domains/ticketing/ticketing.routes') }
```

### Micro Frontends (when applicable)
- Prefer Native Federation (`@angular-architects/native-federation`) for esbuild projects
- Use Module Federation (`@angular-architects/module-federation`) for webpack projects
- Expose route configs or standalone components — NEVER expose AppModule
- Share Angular packages as singletons with `strictVersion: true`
- Use manifest files for dynamic remote configuration
- Shell provides global services (HttpClient, etc.)

## Test Patterns

Vitest is the default test runner. Run tests in **browser mode** via Playwright for realistic component testing.

**Setup (`angular.json`):**
```json
"test": {
  "builder": "@angular/build:unit-test",
  "options": { "browsers": ["Chromium"] },
  "configurations": {
    "ci": { "watch": false, "browsers": ["ChromiumHeadless"] }
  }
}
```

**Install browser mode:** `ng add @vitest/browser-playwright && npx playwright install`

**Reusable mock provider pattern (define once, import everywhere):**
```typescript
// src/app/testing/provide-test-config.ts
export function provideTestConfig(): Provider {
  return { provide: ConfigService, useValue: { baseUrl: '', model: '' } };
}
```

### Feature Component (smart — uses page locators, mocks HTTP)
```typescript
import { page } from 'vitest/browser';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';

describe('FlightSearch', () => {
  let ctrl: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [FlightSearch],
      providers: [provideRouter([]), provideHttpClientTesting(), provideTestConfig()],
    }).compileComponents();

    TestBed.createComponent(FlightSearch);
    ctrl = TestBed.inject(HttpTestingController);

    // Drain the initial httpResource request
    const req = await vi.waitFor(() => ctrl.expectOne('/api/flights?from=Graz&to=Hamburg'));
    req.flush([]);
  });

  afterEach(() => ctrl.verify());

  it('disables search when fields are empty', async () => {
    await page.getByLabelText('From').fill('');
    await page.getByLabelText('To').fill('');
    await expect.element(page.getByRole('button', { name: 'Search' })).toBeDisabled();
  });

  it('shows results after search', async () => {
    await page.getByLabelText('From').fill('Graz');
    await page.getByLabelText('To').fill('Hamburg');
    await page.getByRole('button', { name: 'Search' }).click();

    const req = await vi.waitFor(() => ctrl.expectOne('/api/flights?from=Graz&to=Hamburg'));
    req.flush(mockFlights);

    await expect.element(page.getByRole('heading', { name: 'Graz - Hamburg' })).toBeVisible();
  });
});
```

**Locator reference:**
| Locator | Matches |
|---|---|
| `page.getByLabelText('From')` | `<input>` with label "From" |
| `page.getByRole('button', { name: 'Search' })` | button with text/aria-label "Search" |
| `page.getByRole('heading', { name: /Paris/ })` | heading matching regex |
| `page.getByTestId('submit-btn')` | `data-testid="submit-btn"` (last resort) |

Use `expect.element(locator)` for browser-aware assertions with built-in retry (`.toBeDisabled()`, `.toBeVisible()`, `.toHaveLength()`).

### UI Component (dumb — tests inputs/outputs)
```typescript
describe('FlightCard', () => {
  it('displays flight details', async () => {
    const fixture = TestBed.createComponent(FlightCard);
    fixture.componentRef.setInput('flight', mockFlight);
    fixture.detectChanges();

    await expect.element(page.getByText('Graz - Hamburg')).toBeVisible();
  });

  it('emits select on button click', async () => {
    const fixture = TestBed.createComponent(FlightCard);
    fixture.componentRef.setInput('flight', mockFlight);
    fixture.detectChanges();

    const spy = vi.spyOn(fixture.componentInstance.selected, 'emit');
    await page.getByRole('button', { name: 'Select' }).click();

    expect(spy).toHaveBeenCalledWith(mockFlight.id);
  });
});
```

### Signal Store (data layer — uses HttpTestingController)
```typescript
describe('FlightStore', () => {
  it('loads flights and exposes them via flightsValue', async () => {
    TestBed.configureTestingModule({
      providers: [FlightStore, provideHttpClientTesting(), provideTestConfig()],
    });

    const store = TestBed.inject(FlightStore);
    const ctrl  = TestBed.inject(HttpTestingController);

    const req = await vi.waitFor(() => ctrl.expectOne('/api/flights?from=Graz&to=Hamburg'));
    req.flush(mockFlights);

    expect(store.flightsValue()).toHaveLength(2);
    expect(store.flightsIsLoading()).toBe(false);
  });
});
```

### Shallow Testing (mock child components)
```typescript
TestBed.overrideComponent(FlightSearch, {
  remove: { imports: [FlightCard] },
  add:    { imports: [MockFlightCard] },
});
```

## Build & Verify Commands

### Angular CLI
```bash
ng test                              # Unit tests (Vitest, watch mode)
ng test --configuration=ci           # Unit tests once, headless (CI)
ng build                             # Production build
ng serve                             # Dev server
npx eslint .                         # Lint check (includes Sheriff rules)
npx prettier --check .               # Format check
```

### Nx Monorepo
```bash
nx test <project>                    # Test single project
nx build <project>                   # Build single project
nx lint <project>                    # Lint single project
nx run-many --target=build --all     # Build all (incremental)
nx run-many --target=test --all      # Test all (incremental)
nx run-many --target=lint --all      # Lint all (incremental)
nx graph                             # Dependency graph
nx affected:graph                    # Affected projects graph
```

### Sheriff (Architecture Enforcement)
```bash
npx eslint .                         # Sheriff rules run as part of ESLint
npx sheriff list src/main.ts         # Inspect which tags Sheriff assigns to each module
```

### Detective (Dependency Visualization & Forensic Analysis)
```bash
npm i @softarc/detective             # Install once
npx detective                        # Launch interactive dependency graph UI
```
Detective visualizes module imports, change coupling, and hotspots. Run it when refactoring boundaries or investigating why a module is difficult to change.

## Anti-Patterns to Avoid

### Architecture Violations
- Creating NgModules for new code
- Putting domain-specific code in `shared`
- Cross-domain imports (booking importing from boarding)
- Bypassing `index.ts` barrel to access module internals
- Stores accessing other stores directly
- Exposing AppModule via Module Federation
- Sharing Angular packages without `singleton: true`

### Style Guide Violations
- Using `*ngIf`, `*ngFor`, `[ngSwitch]` instead of `@if`, `@for`, `@switch`
- Using `[ngClass]` / `[ngStyle]` instead of `[class.*]` / `[style.*]`
- Constructor injection instead of `inject()`
- Naming event handlers `handleClick()` / `onClick()` instead of action names like `saveUser()`
- Prefixing outputs with `on` (e.g., `onSaved` instead of `saved`)
- Using generic filenames (`utils.ts`, `helpers.ts`, `common.ts`)
- Non-kebab-case filenames (`userProfile.ts` instead of `user-profile.ts`)
- Missing `readonly` on inputs, outputs, models, and queries
- Missing lifecycle interfaces (`ngOnInit` without `implements OnInit`)
- Complex inline logic in lifecycle hooks instead of delegating to named methods
- Complex template expressions instead of extracting to `computed()`
- Method calls in templates instead of `computed()` signals (performance)
- DOM access in `ngAfterViewInit` instead of `afterNextRender()`
- Impure pipes (`pure: false`) without documented justification
- `@for` without `track`, or using `$index` when items have unique ids
- Missing `@empty` block for `@for` loops over potentially empty collections
- Using RxJS for synchronous derived state (use signals instead)
- `// @ts-ignore` or disabling linters without documented justification
- Missing `protected` on template-only members that are not public API

### Data & Forms Violations
- Using reactive forms (`FormBuilder`, `FormGroup`) or template-driven forms (`ngModel`) instead of Signal Forms
- Raw `HttpClient` calls in components instead of `httpResource` / `rxResource`
- `HttpClient` inside `withMethods` instead of `withMutations` + `httpMutation`
- `withDevtools` included in production bundle (must use environment file pattern)
- `undefined` as a Signal Form field value — use `null` or a typed default
- Subscribing to `ActivatedRoute.params` when `withComponentInputBinding()` is configured
- Accessing `viewChild` / `contentChild` results outside `afterNextRender` / `afterRenderEffect`
- Chained `effect()` calls that react to each other — use `computed()` instead

## Agentic UI (AI-Integrated Components)
Use `@angular-architects/hashbrown` when adding conversational AI or generative UI to an Angular application.

```typescript
import { chatResource, uiChatResource } from '@angular-architects/hashbrown';

// Conversational assistant with tool calling
@Component({ ... })
export class AssistantComponent {
  protected readonly chat = chatResource({
    systemPrompt: 'You are a flight booking assistant.',
    tools: [searchFlightsTool, bookFlightTool],
  });
}
```

```typescript
// Generative UI — AI selects which dumb components to render
@Component({ ... })
export class GenerativeSearch {
  protected readonly uiChat = uiChatResource({
    components: [FlightCard, HotelCard, ErrorCard], // AI picks from this palette
    systemPrompt: 'Return UI components matching the user query.',
  });
}
```

**Generative UI architecture rules:**
- AI-controlled components MUST be dumb (no injected stores, no side effects)
- Wrap each dumb component in a thin smart wrapper that handles store interaction
- Describe each component to the model via metadata so the AI knows when to use it
- `FormValueControl<T>` components are AI-compatible out of the box — no extra wiring needed
- Keep tool implementations in the data layer (services), not inside component classes

## Project-Specific Expansion
<!-- Add project-specific Angular conventions, dependencies, and patterns here -->
<!-- Examples: design system components, API client conventions, environment config -->
