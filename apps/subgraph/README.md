# Subgraph Deployment and Client Usage

This guide details the steps required to deploy the provided subgraph to supported subgraph hosting platforms (e.g., Goldsky, Protofire etc.).

## Prerequisites

Before you begin, ensure you have the following installed and set up:

1.  **Node.js and npm/yarn:** The subgraph development and client rely on Node.js. Download and install it from [nodejs.org](https://nodejs.org/). npm is included, or you can install yarn ([yarnpkg.com](https://classic.yarnpkg.com/en/docs/install)). **Ensure you have Node.js version 20.18.1 or higher.**
2.  **Graph CLI:** This command-line tool is essential for interacting with subgraphs (code generation, building). Install it globally:
    ```bash
    npm install -g @graphprotocol/graph-cli
    # or
    yarn global add @graphprotocol/graph-cli
    ```
    Refer to the [Graph CLI documentation](https://github.com/graphprotocol/graph-tooling/tree/main/packages/cli) for more details.
3.  **Goldsky Account:** You need an account on Goldsky to host your subgraph. Sign up at [goldsky.com](https://goldsky.com/).
4.  **Goldsky CLI:** This tool allows you to deploy subgraphs to the Goldsky platform. Follow the installation instructions in the [Goldsky Documentation](https://docs.goldsky.com/introduction).

## Deploying the Subgraph to Goldsky

Follow these steps to build and deploy the subgraph:

1.  **Navigate to Subgraph Directory:**
    Open your terminal and change to the `subgraph` directory within the project:

    ```bash
    cd path/to/pdp-explorer/subgraph
    ```

2.  **Install Dependencies:**
    Install the necessary node modules:

    ```bash
    npm install
    # or
    yarn install
    ```

3.  **Generate Code:**
    The Graph CLI uses the `subgraph.yaml` manifest and GraphQL schema (`schema.graphql`) to generate AssemblyScript types.

    ```bash
    graph codegen
    ```

4.  **Build the Subgraph:**
    Compile your subgraph code into WebAssembly (WASM).

    ```bash
    graph build
    ```

5.  **Authenticate with Goldsky:**
    Log in to your Goldsky account using the CLI. Go to settings section of your Goldsky dashboard to get your API key.

    ```bash
    goldsky login
    ```

6.  **Deploy to Goldsky:**
    Use the Goldsky CLI to deploy your built subgraph.

    ```bash
    goldsky subgraph deploy <your-subgraph-name>/<version> --path ./
    ```

    - Replace `<your-subgraph-name>` with the desired name for your subgraph deployment on Goldsky (e.g., `payments-subgraph`). You can create/manage this name in your Goldsky dashboard.
    - Replace `<version>` with a version identifier (e.g., `v0.0.1`).
    - You can manage your deployments and find your subgraph details in the [Goldsky Dashboard](https://app.goldsky.com/). The deployment command will output the GraphQL endpoint URL for your subgraph upon successful completion. **Copy this URL**, as you will need it for the client.

7.  **Tag the Subgraph (Optional):**
    Tag the subgraph you deployed in step 6.

    ```bash
    goldsky subgraph tag create <your-subgraph-name>/<version> --tag <tag-name>
    ```

    - Replace `<tag-name>` with a tag name (e.g., `mainnet`).

    Remove the tag when you want to deploy a new version of the subgraph.

    ```bash
    goldsky subgraph tag delete <your-subgraph-name>/<version> --tag <tag-name>
    ```

## Modifying and Redeploying the Subgraph

If you need to make changes to the subgraph's logic, schema, or configuration, follow these general steps:

1.  **Modify Code:** Edit the relevant files:

    - `schema.graphql`: To change the data structure and entities being stored.
    - `subgraph.yaml`: To update contract addresses, ABIs, start blocks, or event handlers.
    - `src/*.ts`: To alter the logic that processes blockchain events and maps them to the defined schema entities.
    - `utils/index.ts`: If modifying shared utility functions or constants.

2.  **Regenerate Code:** After modifying the schema or manifest, always regenerate the AssemblyScript types:

    ```bash
    graph codegen
    ```

3.  **Rebuild:** Compile the updated subgraph code:

    ```bash
    graph build
    ```

4.  **Redeploy:** Deploy the new version to Goldsky. It's good practice to increment the version number:
    ```bash
    goldsky subgraph deploy <your-subgraph-name>/<new-version> --path ./
    ```
    Replace `<new-version>` (e.g., `v0.0.2`).

**Development Resources:**

- **AssemblyScript:** Subgraph mappings are written in AssemblyScript, a subset of TypeScript that compiles to Wasm. Learn more at [https://www.assemblyscript.org/](https://www.assemblyscript.org/).
- **The Graph Documentation:** The official documentation covers subgraph development in detail: [https://thegraph.com/docs/en/subgraphs/developing/creating/starting-your-subgraph/](https://thegraph.com/docs/en/subgraphs/developing/creating/starting-your-subgraph/).

## Further Information

- **Graph Protocol Documentation:** [https://thegraph.com/docs/en/](https://thegraph.com/docs/en/)
- **Goldsky Documentation:** [https://docs.goldsky.com/](https://docs.goldsky.com/)
