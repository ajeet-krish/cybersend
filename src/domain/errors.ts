// Shared domain error for rule violations (validation, lifecycle guards). Repositories throw
// these so screens get one error shape to present.

export class DomainValidationError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'DomainValidationError';
    this.code = code;
  }
}
