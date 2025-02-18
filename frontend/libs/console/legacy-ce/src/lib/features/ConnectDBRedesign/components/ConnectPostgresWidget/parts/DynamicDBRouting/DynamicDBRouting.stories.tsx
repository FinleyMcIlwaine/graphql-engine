import { expect } from '@storybook/jest';
import { ComponentStory, ComponentMeta } from '@storybook/react';
import { userEvent, waitFor, within } from '@storybook/testing-library';
import { handlers } from '../../../../../../mocks/metadata.mock';
import { ReactQueryDecorator } from '../../../../../../storybook/decorators/react-query';
import { DynamicDBRouting } from './DynamicDBRouting';

export default {
  component: DynamicDBRouting,
  decorators: [ReactQueryDecorator()],
  parameters: {
    msw: handlers({ delay: 500 }),
  },
} as ComponentMeta<typeof DynamicDBRouting>;

export const Default: ComponentStory<typeof DynamicDBRouting> = () => (
  <DynamicDBRouting sourceName="default" />
);

Default.play = async ({ args, canvasElement }) => {
  const canvas = within(canvasElement);

  await waitFor(() => {
    expect(canvas.getByLabelText('Database Tenancy')).toBeInTheDocument();
  });

  // click on Database Tenancy
  const radioTenancy = canvas.getByLabelText('Database Tenancy');
  userEvent.click(radioTenancy);

  // click on "Add Connection"
  const buttonAddConnection = canvas.getByText('Add Connection');
  userEvent.click(buttonAddConnection);

  // write "test" in the input text with testid "name"
  const inputName = canvas.getByTestId('name');
  userEvent.type(inputName, 'test');

  // write "test" in the input text with testid "configuration.connectionInfo.databaseUrl.url"
  const inputDatabaseUrl = canvas.getByTestId(
    'configuration.connectionInfo.databaseUrl.url'
  );
  userEvent.type(inputDatabaseUrl, 'test');

  // click on submit
  const buttonSubmit = canvas.getByText('Submit');
  userEvent.click(buttonSubmit);
};
