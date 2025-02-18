import { get, isEmpty, set, unset, isObjectLike } from 'lodash';
import { RowPermissionsState, PermissionType } from '../types';
import { allOperators } from '../../../../../../../components/Services/Data/TablePermissions/PermissionBuilder/utils';
import { GraphQLType, isScalarType } from 'graphql';

const getKeyPath = ({
  keyPath,
  newKey,
  permissionsState,
  type,
}: {
  permissionsState: Pick<RowPermissionsState, 'permissions' | 'operators'>;
  keyPath: string[];
  newKey: string;
  type?: PermissionType;
}) => {
  // Store value before deleting key
  const value = get(permissionsState, ['permissions', ...keyPath]);
  let path = keyPath;

  const isNestedComparator =
    isComparator(newKey) &&
    newKey !== '_exists' && // ignore _exists which is a special comparator
    path.length >= 1;

  if (!isEmpty(value) || type === 'relationship' || isNestedComparator) {
    path = replacePath(keyPath, permissionsState);
  }

  const previousKey = keyPath[keyPath.length - 1];
  if ((previousKey === '_not' && newKey === '_and') || newKey === '_or') {
    path = replacePath(keyPath, permissionsState);
  }

  if (newKey === '') return ['permissions', ...path];

  return appendToPath(path, newKey);
};

function replacePath(
  keyPath: string[],
  permissionsState: Pick<RowPermissionsState, 'permissions' | 'operators'>
) {
  unset(permissionsState, ['permissions', ...keyPath]);
  return keyPath.slice(0, -1);
}

function appendToPath(path: string[], newKey: string) {
  return ['permissions', ...path, newKey];
}

const getInitialValue = (key: string, type?: PermissionType) => {
  switch (key) {
    case '_and':
      return [{}];
    case '_or':
      return [{}];
    case '_not':
      return {};
    case '_exists':
      return {
        _where: {},
        _table: {},
      };
    case '_nin':
    case '_in':
      return [''];
  }

  switch (type) {
    case 'column':
      // Depends on column type
      return { _eq: '' };
    case 'comparator':
      // Depends on comparator type
      return '';
  }
  return {};
};

export const updateKey = ({
  permissionsState,
  newKey,
  keyPath,
  type,
}: {
  permissionsState: Pick<RowPermissionsState, 'permissions' | 'operators'>;
  newKey: string; // New key to be set
  keyPath: string[]; // Path to the key to be deleted
  type?: PermissionType;
}) => {
  const clone = { ...permissionsState };
  const path = getKeyPath({ permissionsState: clone, keyPath, newKey, type });
  const value = getInitialValue(newKey, type);

  const parentKey = path[path.length - 1];
  const parentIsArray = parseInt(parentKey);
  if (parentIsArray) {
    const prevPath = path.slice(0, -1);
    const obj = get(clone, prevPath);
    const filtered = obj.filter((o: Record<string, string>) => !isEmpty(o));
    return set(clone, prevPath, filtered.length ? filtered : [{}]);
  }

  return set(clone, path, value);
};

export const isComparator = (k: string) => {
  return allOperators.find(o => o === k);
};

export const isPrimitive = (value: any) => {
  return !isObjectLike(value);
};

export function graphQLTypeToJsType(
  value: string,
  type: GraphQLType | undefined
): boolean | string | number {
  if (!isScalarType(type)) {
    return value;
  }
  if (type.name === 'Int' || type.name === 'ID' || type.name === 'Float') {
    return Number(value);
  } else if (type.name === 'Boolean') {
    return Boolean(value);
  }

  // Default to string on custom scalars since we have no way of knowing if they map to a number or boolean
  return value;
}

export function isColumnComparator(comparator: string) {
  return (
    comparator === '_ceq' ||
    comparator === '_cne' ||
    comparator === '_cgt' ||
    comparator === '_cge' ||
    comparator === '_clt' ||
    comparator === '_cle'
  );
}
