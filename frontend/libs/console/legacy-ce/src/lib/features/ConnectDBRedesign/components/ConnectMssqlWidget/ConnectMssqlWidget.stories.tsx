import { ComponentStory, ComponentMeta } from '@storybook/react';
import { ConnectMssqlWidget } from './ConnectMssqlWidget';
import { ReactQueryDecorator } from '../../../../storybook/decorators/react-query';
import { handlers } from '../../mocks/handlers.mock';
import { userEvent, waitFor, within } from '@storybook/testing-library';
import { expect } from '@storybook/jest';

export default {
  component: ConnectMssqlWidget,
  decorators: [ReactQueryDecorator()],
  parameters: {
    msw: handlers(),
  },
} as ComponentMeta<typeof ConnectMssqlWidget>;

export const CreateConnection: ComponentStory<
  typeof ConnectMssqlWidget
> = () => {
  return (
    <div className="flex justify-center">
      <div className="w-1/2">
        <ConnectMssqlWidget />
      </div>
    </div>
  );
};

export const MSSQLCreateConnection: ComponentStory<
  typeof ConnectMssqlWidget
> = () => {
  return (
    <div className="flex justify-center">
      <div className="w-1/2">
        <ConnectMssqlWidget />
      </div>
    </div>
  );
};

MSSQLCreateConnection.storyName = '🧪 MSSQL Interaction test (add database)';

MSSQLCreateConnection.play = async ({ canvasElement }) => {
  const canvas = within(canvasElement);

  // verify if the right title is displayed. It should contain the word `postgres`.
  expect(await canvas.findByText('Connect MSSQL Database')).toBeInTheDocument();

  // verify if all the fields are present (in oss mode)

  expect(await canvas.findByLabelText('Database name')).toBeInTheDocument();

  // There should be exactly 3 supported database connection options
  const radioOptions = await canvas.findAllByLabelText('Connect Database via');
  expect(radioOptions.length).toBe(2);

  const databaseUrlOption = await canvas.findByTestId(
    'configuration.connectionInfo.connectionString.connectionType-databaseUrl'
  );
  expect(databaseUrlOption).toBeInTheDocument();
  expect(databaseUrlOption).toBeChecked();

  // Expect the first option to have the following input fields
  expect(
    await canvas.findByPlaceholderText(
      'Driver={ODBC Driver 18 for SQL Server};Server=serveraddress;Database=dbname;Uid=username;Pwd=password'
    )
  ).toBeInTheDocument();

  // click on the environment variable option and verify if the correct fields are shown
  const environmentVariableOption = await canvas.findByTestId(
    'configuration.connectionInfo.connectionString.connectionType-envVar'
  );
  userEvent.click(environmentVariableOption);
  expect(
    await canvas.findByPlaceholderText('HASURA_GRAPHQL_DB_URL_FROM_ENV')
  ).toBeInTheDocument();

  // Find and click on advanced settings
  userEvent.click(await canvas.findByText('Advanced Settings'));
  expect(await canvas.findByText('Total Max Connections')).toBeInTheDocument();
  expect(await canvas.findByText('Idle Timeout')).toBeInTheDocument();
};

export const MSSQLEditConnection: ComponentStory<
  typeof ConnectMssqlWidget
> = () => {
  return (
    <div className="flex justify-center">
      <div className="w-1/2">
        <ConnectMssqlWidget dataSourceName="mssql1" />
      </div>
    </div>
  );
};

MSSQLEditConnection.storyName = '🧪 MSSQL Edit Databaase Interaction test';

MSSQLEditConnection.play = async ({ canvasElement }) => {
  const canvas = within(canvasElement);

  // verify if the right title is displayed. It should contain the word `postgres`.
  expect(await canvas.findByText('Edit MSSQL Connection')).toBeInTheDocument();

  // verify if all the fields are present (in oss mode)

  await waitFor(
    async () => {
      expect(await canvas.findByLabelText('Database name')).toHaveValue(
        'mssql1'
      );
    },
    { timeout: 5000 }
  );

  const radioOptions = await canvas.findAllByLabelText('Connect Database via');
  expect(radioOptions.length).toBe(2);
  const databaseUrlOption = await canvas.findByTestId(
    'configuration.connectionInfo.connectionString.connectionType-databaseUrl'
  );
  expect(databaseUrlOption).toBeChecked();
  expect(
    await canvas.findByTestId(
      'configuration.connectionInfo.connectionString.url'
    )
  ).toHaveValue(
    'DRIVER={ODBC Driver 17 for SQL Server};SERVER=host.docker.internal;DATABASE=bikes;Uid=SA;Pwd=reallyStrongPwd123'
  );

  // Find and click on advanced settings
  userEvent.click(await canvas.findByText('Advanced Settings'));
  expect(
    await canvas.findByTestId(
      'configuration.connectionInfo.poolSettings.totalMaxConnections'
    )
  ).toHaveValue(50);
  expect(
    await canvas.findByTestId(
      'configuration.connectionInfo.poolSettings.idleTimeout'
    )
  ).toHaveValue(180);

  // find and click on graphql customization settings
  userEvent.click(await canvas.findByText('GraphQL Customization'));
  expect(
    await canvas.findByTestId('customization.rootFields.namespace')
  ).toHaveValue('some_field_name');
  expect(
    await canvas.findByTestId('customization.rootFields.prefix')
  ).toHaveValue('some_field_name_prefix');
  expect(
    await canvas.findByTestId('customization.rootFields.suffix')
  ).toHaveValue('some_field_name_suffix');
  expect(
    await canvas.findByTestId('customization.typeNames.prefix')
  ).toHaveValue('some_type_name_prefix');
  expect(
    await canvas.findByTestId('customization.typeNames.suffix')
  ).toHaveValue('some_type_name_suffix');
};
