# DBeaver CloudBeaver

DBeaver CloudBeaver is a web-based database administration tool that provides a modern, cloud-native interface for managing multiple database connections. This template deploys CloudBeaver with automatic admin user creation for seamless setup.

## Quick Start

1. **Configure Admin Credentials**: Update the `values.yaml` file with your desired admin username and password:
   ```yaml
   admin:
     name: your-admin-username
     password: your-secure-password
   ```

2. **Install the Application**: Click the "Install App" button in the Control Plane UI

3. **Access DBeaver**: Once deployed, open the workload and login with your configured admin credentials

## Admin User Setup

The template automatically creates an admin user at startup using the values specified in `values.yaml`:

- **`admin.name`**: The username for the admin account
- **`admin.password`**: The password for the admin account

These credentials are securely stored as a Control Plane secret and automatically configured when the container starts. No manual user creation is required - simply login with your configured credentials after deployment.

## Usage

After deployment and login:
1. **Create Database Connections**: Use the connection wizard to add your database servers
2. **Manage Data**: Browse, query, and edit your database content
3. **Export/Import**: Transfer data between different database systems
4. **SQL Editor**: Write and execute SQL queries with syntax highlighting

## Supported Databases

CloudBeaver supports PostgreSQL, MySQL/MariaDB, MongoDB, Redis, SQLite, Oracle, SQL Server, and many more database systems.

## Additional Resources

- [DBeaver CloudBeaver Documentation](https://cloudbeaver.io/docs/)
- [DBeaver GitHub](https://github.com/dbeaver/cloudbeaver)
