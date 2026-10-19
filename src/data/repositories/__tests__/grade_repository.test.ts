// Grade repository tests (US-9): built-in schemes, custom ordered levels, delete in use blocked.

import { create_test_database } from '../../db/testing';
import { DomainValidationError } from '../../../domain/errors';
import { FONT_SCALE, V_SCALE } from '../../../domain/grade/builtin_schemes';

describe('GradeRepository', () => {
  test('lists built-in V scale and Font schemes with ordered levels', async () => {
    const { repos } = await create_test_database();
    const systems = await repos.grades.listSystems();

    const v_scale = systems.find((system) => system.id === V_SCALE.id);
    const font = systems.find((system) => system.id === FONT_SCALE.id);
    expect(v_scale?.isBuiltin).toBe(true);
    expect(font?.isBuiltin).toBe(true);
    expect(v_scale?.levels[0]?.label).toBe('V0');
    expect(font?.levels.map((level) => level.label)).toContain('6a+');
  });

  test('creates a custom scheme of named ordered levels', async () => {
    const { repos } = await create_test_database();
    const system = await repos.grades.createCustomSystem({
      name: ' My gym colors ',
      levelLabels: ['green', 'blue', 'black'],
    });

    expect(system.name).toBe('My gym colors');
    expect(system.levels.map((level) => level.label)).toEqual(['green', 'blue', 'black']);
    expect(system.levels[0]?.id).toBe(`${system.id}_l0`);

    const systems = await repos.grades.listSystems();
    expect(systems.filter((candidate) => candidate.id === system.id)).toHaveLength(1);
  });

  test('rejects invalid custom schemes', async () => {
    const { repos } = await create_test_database();
    await expect(repos.grades.createCustomSystem({ name: ' ', levelLabels: ['a'] })).rejects.toThrow(DomainValidationError);
    await expect(repos.grades.createCustomSystem({ name: 'x', levelLabels: [] })).rejects.toThrow('at least one');
    await expect(repos.grades.createCustomSystem({ name: 'x', levelLabels: ['a', 'a'] })).rejects.toThrow('unique');
  });

  test('renaming works for custom schemes only', async () => {
    const { repos } = await create_test_database();
    const system = await repos.grades.createCustomSystem({ name: 'Old', levelLabels: ['one'] });
    const renamed = await repos.grades.renameCustomSystem(system.id, ' New ');
    expect(renamed.name).toBe('New');

    await expect(repos.grades.renameCustomSystem(V_SCALE.id, 'Nope')).rejects.toThrow('Built-in');
    await expect(repos.grades.renameCustomSystem('missing', 'x')).rejects.toThrow('not found');
  });

  test('deleting a scheme in use is blocked; deleting a used built-in is blocked (US-9.4)', async () => {
    const { repos } = await create_test_database();
    const gym = await repos.gyms.create({ name: 'Gym' });
    const system = await repos.grades.createCustomSystem({ name: 'Circuit', levelLabels: ['easy', 'hard'] });
    await repos.climbs.create({
      gymId: gym.id,
      gradeSystem: system.id,
      gradeRaw: system.levels[0]?.id ?? null,
    });

    await expect(repos.grades.deleteCustomSystem(system.id)).rejects.toThrow('used by 1 climb');
    await expect(repos.grades.deleteCustomSystem(V_SCALE.id)).rejects.toThrow('Built-in');
  });

  test('deleting an unused custom scheme removes it and resets a stale default', async () => {
    const { repos } = await create_test_database();
    const system = await repos.grades.createCustomSystem({ name: 'Temp', levelLabels: ['a'] });
    await repos.grades.setDefaultSystem(system.id);
    expect(await repos.grades.getDefaultSystemId()).toBe(system.id);

    await repos.grades.deleteCustomSystem(system.id);
    expect(await repos.grades.getDefaultSystemId()).toBe(V_SCALE.id);
    const systems = await repos.grades.listSystems();
    expect(systems.some((candidate) => candidate.id === system.id)).toBe(false);
  });

  test('validates (scheme, level) pairs for climbs', async () => {
    const { repos } = await create_test_database();
    const system = await repos.grades.createCustomSystem({ name: 'Colors', levelLabels: ['green', 'blue'] });

    await repos.grades.assertValidGrade(system.id, system.levels[1]?.id ?? null);
    await repos.grades.assertValidGrade(system.id, null);
    await expect(repos.grades.assertValidGrade(system.id, 'missing_level')).rejects.toThrow('does not exist');
    await expect(repos.grades.assertValidGrade('no_such_scheme', 'x')).rejects.toThrow('Unknown grade scheme');
  });

  test('default scheme falls back to the V scale', async () => {
    const { repos } = await create_test_database();
    expect(await repos.grades.getDefaultSystemId()).toBe(V_SCALE.id);
    await repos.grades.setDefaultSystem(FONT_SCALE.id);
    expect(await repos.grades.getDefaultSystemId()).toBe(FONT_SCALE.id);
    await expect(repos.grades.setDefaultSystem('missing')).rejects.toThrow('not found');
  });
});
